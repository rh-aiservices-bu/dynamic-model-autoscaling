#!/bin/bash
#
# KEDA Autoscaling Load Test for vLLM InferenceService
# Monitors vllm:num_requests_waiting and vllm:num_requests_running metrics
# to observe KEDA autoscaling behavior
#

# Configuration - auto-detect from cluster if not set
NAMESPACE="${NAMESPACE:-llm}"

# Auto-detect InferenceService and route
if [ -z "$INFERENCESERVICE" ]; then
    INFERENCESERVICE=$(oc get inferenceservice -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$INFERENCESERVICE" ]; then
        echo "Error: No InferenceService found in namespace $NAMESPACE"
        exit 1
    fi
fi

DEPLOYMENT="${DEPLOYMENT:-${INFERENCESERVICE}-predictor}"

# Auto-detect route URL
if [ -z "$API_BASE_URL" ]; then
    ROUTE_HOST=$(oc get route -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
    if [ -z "$ROUTE_HOST" ]; then
        echo "Error: No route found in namespace $NAMESPACE"
        exit 1
    fi
    API_BASE_URL="https://${ROUTE_HOST}/v1"
fi

# Auto-detect model name from ServingRuntime
if [ -z "$MODEL_NAME" ]; then
    MODEL_NAME=$(oc get servingruntime -n "$NAMESPACE" "$INFERENCESERVICE" -o jsonpath='{.spec.containers[0].args}' 2>/dev/null | sed -n 's/.*--served-model-name=\([^"]*\).*/\1/p' | head -1)
    if [ -z "$MODEL_NAME" ]; then
        MODEL_NAME="$INFERENCESERVICE"
    fi
fi

DURATION="${DURATION:-120}"          # Duration in seconds
MAX_TOKENS="${MAX_TOKENS:-500}"      # Longer responses = more load
MONITOR_INTERVAL="${MONITOR_INTERVAL:-5}"  # Metrics check interval
DEBUG="${DEBUG:-false}"              # Show 1-in-10 request/response details

# Adaptive rate control
TARGET_WAITING="${TARGET_WAITING:-3}"                       # Desired num_requests_waiting
MAX_WAITING="${MAX_WAITING:-$((TARGET_WAITING * 2))}"       # Back off hard above this
TARGET_RUNNING="${TARGET_RUNNING:-20}"                      # Max concurrent running before back-off
INITIAL_RATE="${INITIAL_RATE:-1}"                           # Starting requests/sec
MIN_RATE="${MIN_RATE:-1}"                                   # Floor
MAX_RATE="${MAX_RATE:-20}"                                  # Ceiling
CURL_TIMEOUT="${CURL_TIMEOUT:-120}"                         # Stall timeout: abort if no data for this long

# Complex prompts that require longer processing time
PROMPTS=(
    "Write a detailed 500-word essay about the history of artificial intelligence from the 1950s to today, covering all major milestones."
    "Explain in comprehensive detail how transformer neural networks work, including the attention mechanism, positional encoding, and training process."
    "Describe the complete step-by-step process of training a large language model from data collection to deployment, with all technical details."
    "Write a comprehensive technical guide to Kubernetes architecture including all components, their interactions, and best practices for production."
    "Explain quantum computing principles in depth, covering qubits, superposition, entanglement, and their potential impact on cryptography and computing."
    "Provide a detailed analysis of microservices architecture patterns, including service mesh, event-driven design, and distributed transaction handling."
    "Write a thorough explanation of GPU acceleration for machine learning, covering CUDA cores, tensor cores, memory hierarchy, and optimization techniques."
)

NUM_PROMPTS=${#PROMPTS[@]}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

get_random_prompt() {
    local idx=$((RANDOM % NUM_PROMPTS))
    echo "${PROMPTS[$idx]}"
}

# Function to get vLLM metrics aggregated across all pods
get_metrics() {
    local tmp_dir=$(mktemp -d /tmp/load-test-metrics-XXXXXX)
    local pod_names=$(oc get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice="$INFERENCESERVICE" \
        --field-selector=status.phase=Running --no-headers -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    # Fetch metrics from all pods in parallel (subshell to isolate wait)
    (
        for pod in $pod_names; do
            oc exec -n "$NAMESPACE" "$pod" -- curl -s localhost:8080/metrics 2>/dev/null > "$tmp_dir/$pod" &
        done
        wait
    )

    # Aggregate across pods
    local total_running=0 total_waiting=0 total_success=0
    for f in "$tmp_dir"/*; do
        [ -f "$f" ] || continue
        local running=$(grep "vllm:num_requests_running{" "$f" | grep -v "#" | awk '{print $2}')
        local waiting=$(grep "vllm:num_requests_waiting{" "$f" | grep -v "#" | awk '{print $2}')
        local success=$(grep "vllm:request_success_total{" "$f" | grep -v "#" | awk '{sum += $2} END {print sum}')
        total_running=$(echo "$total_running + ${running:-0}" | bc)
        total_waiting=$(echo "$total_waiting + ${waiting:-0}" | bc)
        total_success=$(echo "$total_success + ${success:-0}" | bc)
    done

    rm -rf "$tmp_dir"
    echo "$total_running $total_waiting $total_success"
}

# Function to get pod count
get_pod_count() {
    oc get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice="$INFERENCESERVICE" --no-headers 2>/dev/null | grep -c "Running"
}

# Function to check HPA/ScaledObject status
get_scaling_status() {
    local hpa=$(oc get hpa -n "$NAMESPACE" --no-headers 2>/dev/null | head -1)
    local so=$(oc get scaledobject -n "$NAMESPACE" --no-headers 2>/dev/null | head -1)
    if [ -n "$hpa" ]; then
        echo "$hpa"
    elif [ -n "$so" ]; then
        echo "$so"
    else
        echo "No autoscaler found"
    fi
}

print_header() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}KEDA Autoscaling Load Test - vLLM Metrics Monitor${NC}                             ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  Endpoint:    ${GREEN}$API_BASE_URL${NC}"
    echo -e "${CYAN}║${NC}  Model:       ${GREEN}$MODEL_NAME${NC}"
    echo -e "${CYAN}║${NC}  Namespace:   ${GREEN}$NAMESPACE${NC}"
    echo -e "${CYAN}║${NC}  Deployment:  ${GREEN}$DEPLOYMENT${NC}"
    echo -e "${CYAN}║${NC}  Duration:    ${GREEN}${DURATION}s${NC}"
    echo -e "${CYAN}║${NC}  Max Tokens:  ${GREEN}$MAX_TOKENS${NC} (longer = more load)"
    echo -e "${CYAN}║${NC}  Rate:        ${GREEN}adaptive${NC} (target_running=${TARGET_RUNNING}, target_waiting=${TARGET_WAITING})"
    echo -e "${CYAN}║${NC}  Rate range:  ${GREEN}${MIN_RATE}-${MAX_RATE} req/s${NC} (timeout=${CURL_TIMEOUT}s)"
    echo -e "${CYAN}║${NC}  Debug:       ${GREEN}$DEBUG${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_metrics_header() {
    echo -e "${BLUE}┌──────────┬────────────┬────────────┬────────────┬──────────┬────────┬────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} ${YELLOW}Time${NC}     ${BLUE}│${NC} ${YELLOW}Running${NC}    ${BLUE}│${NC} ${YELLOW}Waiting${NC}    ${BLUE}│${NC} ${YELLOW}Success${NC}    ${BLUE}│${NC} ${YELLOW}Pods${NC}     ${BLUE}│${NC} ${YELLOW}Rate${NC}   ${BLUE}│${NC} ${YELLOW}Requests Sent${NC}      ${BLUE}│${NC}"
    echo -e "${BLUE}├──────────┼────────────┼────────────┼────────────┼──────────┼────────┼────────────────────┤${NC}"
}

print_metrics_row() {
    local elapsed=$1
    local running=$2
    local waiting=$3
    local success=$4
    local pods=$5
    local rate=$6
    local sent=$7

    # Color coding based on values
    local running_color="${GREEN}"
    local waiting_color="${GREEN}"

    if (( $(echo "$running > 10" | bc -l 2>/dev/null || echo "0") )); then
        running_color="${YELLOW}"
    fi
    if (( $(echo "$running > 25" | bc -l 2>/dev/null || echo "0") )); then
        running_color="${RED}"
    fi
    if (( $(echo "$waiting > 0" | bc -l 2>/dev/null || echo "0") )); then
        waiting_color="${YELLOW}"
    fi
    if (( $(echo "$waiting > 5" | bc -l 2>/dev/null || echo "0") )); then
        waiting_color="${RED}"
    fi

    printf "${BLUE}│${NC} %8s ${BLUE}│${NC} ${running_color}%10s${NC} ${BLUE}│${NC} ${waiting_color}%10s${NC} ${BLUE}│${NC} %10s ${BLUE}│${NC} %8s ${BLUE}│${NC} %6s ${BLUE}│${NC} %18s ${BLUE}│${NC}\n" \
        "${elapsed}s" "$running" "$waiting" "$success" "$pods" "${rate}/s" "$sent"
}

print_metrics_footer() {
    echo -e "${BLUE}└──────────┴────────────┴────────────┴────────────┴──────────┴────────┴────────────────────┘${NC}"
}

plot_throughput_graph() {
    local data_file=$1
    local -a elapsed=() cumulative=() pods_arr=()

    # Read logged data
    local base_success=""
    while IFS=' ' read -r t s p; do
        local s_int=${s%%.*}
        if [ -z "$base_success" ]; then base_success=$s_int; fi
        elapsed+=("$t")
        cumulative+=("$(( s_int - base_success ))")
        pods_arr+=("$p")
    done < "$data_file"

    local n=${#elapsed[@]}
    if [ "$n" -le 1 ]; then return; fi

    local max_val=${cumulative[$((n-1))]}
    if [ "$max_val" -le 0 ]; then return; fi

    local chart_height=15
    echo ""
    echo -e "${YELLOW}Cumulative Successful Requests Over Time:${NC}"
    echo ""

    # Render rows top to bottom
    for (( row=chart_height; row>=1; row-- )); do
        local threshold=$(( row * max_val / chart_height ))
        if [ "$threshold" -eq 0 ]; then threshold=1; fi
        printf "${BLUE}%4d${NC} ┤" "$threshold"
        for (( i=0; i<n; i++ )); do
            if [ "${cumulative[$i]}" -ge "$threshold" ]; then
                printf "${GREEN}█${NC}"
            else
                printf " "
            fi
        done
        echo ""
    done

    # X-axis
    printf "   0 ┼"
    printf '─%.0s' $(seq 1 "$n")
    echo ""

    # Time labels
    printf "      "
    local step=$(( n / 5 ))
    if [ "$step" -lt 1 ]; then step=1; fi
    local i=0
    while [ "$i" -lt "$n" ]; do
        if (( i % step == 0 )); then
            local label="${elapsed[$i]}s"
            printf "%s" "$label"
            i=$(( i + ${#label} ))
        else
            printf " "
            i=$(( i + 1 ))
        fi
    done
    echo ""

    # Pod scale-up annotations
    local prev_p="${pods_arr[0]}"
    for (( i=1; i<n; i++ )); do
        if [ "${pods_arr[$i]}" != "$prev_p" ]; then
            local pos=$((6 + i))
            printf "%*s${CYAN}↑ Scaled to %s pod(s)${NC}\n" "$pos" "" "${pods_arr[$i]}"
            prev_p="${pods_arr[$i]}"
        fi
    done
}

# Main execution
print_header

echo -e "${CYAN}Initial State:${NC}"
initial_metrics=$(get_metrics)
initial_pods=$(get_pod_count)
echo -e "  Metrics: Running=$(echo $initial_metrics | awk '{print $1}'), Waiting=$(echo $initial_metrics | awk '{print $2}'), Success=$(echo $initial_metrics | awk '{print $3}')"
echo -e "  Pods: $initial_pods"
echo -e "  Autoscaler: $(get_scaling_status)"
echo ""

echo -e "${CYAN}Starting sustained load test...${NC}"
echo ""

# Start metrics monitoring in background
print_metrics_header

START_TIME=$SECONDS

# Shared files for communication between monitor and sender
RATE_CONTROL=$(mktemp /tmp/load-test-rate.XXXXXX)
SENT_COUNTER=$(mktemp /tmp/load-test-sent.XXXXXX)
METRICS_LOG=$(mktemp /tmp/load-test-metrics.XXXXXX)
echo "$INITIAL_RATE" > "$RATE_CONTROL"
echo "0" > "$SENT_COUNTER"

# Cleanup: kill background load generator and all its children on exit
cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping load test and cleaning up background processes...${NC}"
    if [ -n "$LOAD_PID" ] && kill -0 $LOAD_PID 2>/dev/null; then
        kill -- -$LOAD_PID 2>/dev/null  # kill the entire process group
        wait $LOAD_PID 2>/dev/null
    fi
    rm -f "$RATE_CONTROL" "$SENT_COUNTER" "$METRICS_LOG"
    print_metrics_footer
    echo -e "${GREEN}Cleanup complete.${NC}"
    exit 0
}
trap cleanup INT TERM

# Background process to send requests (run in its own process group)
set -m
(
    REQUEST_COUNT=0
    END_TIME=$((SECONDS + DURATION))
    while [ $SECONDS -lt $END_TIME ]; do
        CURRENT_RATE=$(cat "$RATE_CONTROL" 2>/dev/null || echo "$MIN_RATE")
        for i in $(seq 1 "$CURRENT_RATE"); do
            PROMPT=$(get_random_prompt)
            REQUEST_COUNT=$((REQUEST_COUNT + 1))
            echo "$REQUEST_COUNT" > "$SENT_COUNTER"
            if [[ "$DEBUG" == "true" ]] && (( REQUEST_COUNT % 10 == 0 )); then
                # Debug: show every 10th request's curl command and response
                echo -e "${YELLOW}[DEBUG] Request #${REQUEST_COUNT}:${NC}" >&2
                echo -e "${CYAN}curl -sk --speed-limit 1 --speed-time $CURL_TIMEOUT -X POST \"$API_BASE_URL/chat/completions\" -H \"Content-Type: application/json\" -d '{\"model\": \"$MODEL_NAME\", \"messages\": [...], \"max_tokens\": $MAX_TOKENS, \"stream\": true}'${NC}" >&2
                RESPONSE=$(curl -sk --speed-limit 1 --speed-time "$CURL_TIMEOUT" -X POST "$API_BASE_URL/chat/completions" \
                    -H "Content-Type: application/json" \
                    -d '{
                        "model": "'"$MODEL_NAME"'",
                        "messages": [{"role": "user", "content": "'"$PROMPT"'"}],
                        "max_tokens": '"$MAX_TOKENS"',
                        "stream": true
                    }' 2>&1)
                echo -e "${YELLOW}[DEBUG] Response #${REQUEST_COUNT} (first 500 chars):${NC} ${RESPONSE:0:500}" >&2
                echo "" >&2
            else
                curl -sk --speed-limit 1 --speed-time "$CURL_TIMEOUT" -X POST "$API_BASE_URL/chat/completions" \
                    -H "Content-Type: application/json" \
                    -d '{
                        "model": "'"$MODEL_NAME"'",
                        "messages": [{"role": "user", "content": "'"$PROMPT"'"}],
                        "max_tokens": '"$MAX_TOKENS"',
                        "stream": true
                    }' > /dev/null 2>&1 &
            fi
        done
        sleep 1
    done
    wait
) &
LOAD_PID=$!
set +m

# Monitor metrics and adjust rate (closed-loop controller)
CURRENT_RATE=$INITIAL_RATE
while kill -0 $LOAD_PID 2>/dev/null; do
    ELAPSED=$((SECONDS - START_TIME))
    TOTAL_SENT=$(cat "$SENT_COUNTER" 2>/dev/null || echo "0")

    metrics=$(get_metrics)
    running=$(echo $metrics | awk '{print $1}')
    waiting=$(echo $metrics | awk '{print $2}')
    success=$(echo $metrics | awk '{print $3}')
    pods=$(get_pod_count)

    # Adaptive rate control based on num_requests_running and num_requests_waiting
    running_int=$(printf "%.0f" "$running" 2>/dev/null || echo "0")
    waiting_int=$(printf "%.0f" "$waiting" 2>/dev/null || echo "0")

    # Scale targets with pod count — more pods = more capacity
    EFFECTIVE_TARGET=$((TARGET_RUNNING * pods))
    RUNNING_HEADROOM=$((EFFECTIVE_TARGET * 3 / 4))

    if [ "$waiting_int" -gt "$MAX_WAITING" ]; then
        # Way too much pressure — drop to minimum
        CURRENT_RATE=$MIN_RATE
    elif [ "$running_int" -ge "$EFFECTIVE_TARGET" ]; then
        # GPU saturated — stop sending until running drains
        CURRENT_RATE=$MIN_RATE
    elif [ "$waiting_int" -ge "$TARGET_WAITING" ]; then
        # Sweet spot for KEDA — hold steady
        :
    elif [ "$running_int" -ge "$RUNNING_HEADROOM" ]; then
        # Approaching capacity — hold steady to avoid overshoot
        :
    else
        # Not enough pressure — ramp up gradually
        CURRENT_RATE=$((CURRENT_RATE + 1))
    fi

    # Clamp to [MIN_RATE, MAX_RATE]
    if [ "$CURRENT_RATE" -lt "$MIN_RATE" ]; then
        CURRENT_RATE=$MIN_RATE
    elif [ "$CURRENT_RATE" -gt "$MAX_RATE" ]; then
        CURRENT_RATE=$MAX_RATE
    fi

    echo "$CURRENT_RATE" > "$RATE_CONTROL"

    print_metrics_row "$ELAPSED" "$running" "$waiting" "$success" "$pods" "$CURRENT_RATE" "$TOTAL_SENT"

    # Log for end-of-run graph
    echo "$ELAPSED $success $pods" >> "$METRICS_LOG"

    sleep $MONITOR_INTERVAL
done

# Wait for load generator to finish
wait $LOAD_PID

print_metrics_footer
echo ""

# Final status
echo -e "${CYAN}Final State (waiting for in-flight requests...):${NC}"
sleep 5
TOTAL_SENT=$(cat "$SENT_COUNTER" 2>/dev/null || echo "0")
final_metrics=$(get_metrics)
final_pods=$(get_pod_count)
echo -e "  Metrics: Running=$(echo $final_metrics | awk '{print $1}'), Waiting=$(echo $final_metrics | awk '{print $2}'), Success=$(echo $final_metrics | awk '{print $3}')"
echo -e "  Pods: $final_pods"
echo -e "  Autoscaler: $(get_scaling_status)"
echo ""

plot_throughput_graph "$METRICS_LOG"
echo ""

rm -f "$RATE_CONTROL" "$SENT_COUNTER" "$METRICS_LOG"
echo -e "${GREEN}Load test completed!${NC}"
echo -e "Total requests sent: $TOTAL_SENT"
echo ""
echo -e "${YELLOW}Key metrics to watch for KEDA autoscaling:${NC}"
echo -e "  - ${CYAN}vllm:num_requests_waiting${NC} > threshold (default: 3) should trigger scale-up"
echo -e "  - ${CYAN}vllm:num_requests_running${NC} shows concurrent processing capacity"
echo -e "  - Pod count should increase when waiting > threshold"
echo ""
echo -e "${YELLOW}If KEDA is not scaling, check:${NC}"
echo -e "  1. oc get scaledobject -n $NAMESPACE"
echo -e "  2. oc describe scaledobject <name> -n $NAMESPACE"
echo -e "  3. oc get hpa -n $NAMESPACE"
