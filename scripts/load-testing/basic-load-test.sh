#!/bin/bash
#
# KEDA Autoscaling Load Test for vLLM InferenceService
# Monitors vllm:num_requests_waiting and vllm:num_requests_running metrics
# to observe KEDA autoscaling behavior
#

# Configuration
API_BASE_URL="${API_BASE_URL:-https://llama32-llm.apps.ocp.zq97n.sandbox2467.opentlc.com/v1}"
MODEL_NAME="${MODEL_NAME:-llama32}"
NAMESPACE="${NAMESPACE:-llm}"
DEPLOYMENT="${DEPLOYMENT:-llama-32-predictor}"
DURATION="${DURATION:-120}"          # Duration in seconds
RATE="${RATE:-10}"                   # Requests per second
MAX_TOKENS="${MAX_TOKENS:-500}"      # Longer responses = more load
MONITOR_INTERVAL="${MONITOR_INTERVAL:-5}"  # Metrics check interval

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

# Function to get vLLM metrics from pod
get_metrics() {
    local metrics=$(oc exec -n "$NAMESPACE" deploy/"$DEPLOYMENT" -- curl -s localhost:8080/metrics 2>/dev/null)
    local running=$(echo "$metrics" | grep "vllm:num_requests_running{" | grep -v "#" | awk '{print $2}')
    local waiting=$(echo "$metrics" | grep "vllm:num_requests_waiting{" | grep -v "#" | awk '{print $2}')
    local success=$(echo "$metrics" | grep "vllm:request_success_total{" | grep -v "#" | awk '{sum += $2} END {print sum}')
    echo "${running:-0} ${waiting:-0} ${success:-0}"
}

# Function to get pod count
get_pod_count() {
    oc get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice="${DEPLOYMENT%-predictor}" --no-headers 2>/dev/null | grep -c "Running"
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
    echo -e "${CYAN}║${NC}  Duration:    ${GREEN}${DURATION}s${NC} @ ${GREEN}${RATE} req/s${NC}"
    echo -e "${CYAN}║${NC}  Max Tokens:  ${GREEN}$MAX_TOKENS${NC} (longer = more load)"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_metrics_header() {
    echo -e "${BLUE}┌──────────┬────────────┬────────────┬────────────┬──────────┬────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} ${YELLOW}Time${NC}     ${BLUE}│${NC} ${YELLOW}Running${NC}    ${BLUE}│${NC} ${YELLOW}Waiting${NC}    ${BLUE}│${NC} ${YELLOW}Success${NC}    ${BLUE}│${NC} ${YELLOW}Pods${NC}     ${BLUE}│${NC} ${YELLOW}Requests Sent${NC}      ${BLUE}│${NC}"
    echo -e "${BLUE}├──────────┼────────────┼────────────┼────────────┼──────────┼────────────────────┤${NC}"
}

print_metrics_row() {
    local elapsed=$1
    local running=$2
    local waiting=$3
    local success=$4
    local pods=$5
    local sent=$6

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

    printf "${BLUE}│${NC} %8s ${BLUE}│${NC} ${running_color}%10s${NC} ${BLUE}│${NC} ${waiting_color}%10s${NC} ${BLUE}│${NC} %10s ${BLUE}│${NC} %8s ${BLUE}│${NC} %18s ${BLUE}│${NC}\n" \
        "${elapsed}s" "$running" "$waiting" "$success" "$pods" "$sent"
}

print_metrics_footer() {
    echo -e "${BLUE}└──────────┴────────────┴────────────┴────────────┴──────────┴────────────────────┘${NC}"
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

TOTAL_SENT=0
START_TIME=$SECONDS

# Background process to send requests
(
    END_TIME=$((SECONDS + DURATION))
    while [ $SECONDS -lt $END_TIME ]; do
        for i in $(seq 1 $RATE); do
            PROMPT=$(get_random_prompt)
            curl -sk -X POST "$API_BASE_URL/chat/completions" \
                -H "Content-Type: application/json" \
                -d '{
                    "model": "'"$MODEL_NAME"'",
                    "messages": [{"role": "user", "content": "'"$PROMPT"'"}],
                    "max_tokens": '"$MAX_TOKENS"'
                }' > /dev/null 2>&1 &
        done
        sleep 1
    done
    wait
) &
LOAD_PID=$!

# Monitor metrics while load is running
while kill -0 $LOAD_PID 2>/dev/null; do
    ELAPSED=$((SECONDS - START_TIME))
    TOTAL_SENT=$((ELAPSED * RATE))

    metrics=$(get_metrics)
    running=$(echo $metrics | awk '{print $1}')
    waiting=$(echo $metrics | awk '{print $2}')
    success=$(echo $metrics | awk '{print $3}')
    pods=$(get_pod_count)

    print_metrics_row "$ELAPSED" "$running" "$waiting" "$success" "$pods" "$TOTAL_SENT"

    sleep $MONITOR_INTERVAL
done

# Wait for load generator to finish
wait $LOAD_PID

print_metrics_footer
echo ""

# Final status
echo -e "${CYAN}Final State (waiting for in-flight requests...):${NC}"
sleep 5
final_metrics=$(get_metrics)
final_pods=$(get_pod_count)
echo -e "  Metrics: Running=$(echo $final_metrics | awk '{print $1}'), Waiting=$(echo $final_metrics | awk '{print $2}'), Success=$(echo $final_metrics | awk '{print $3}')"
echo -e "  Pods: $final_pods"
echo -e "  Autoscaler: $(get_scaling_status)"
echo ""

echo -e "${GREEN}Load test completed!${NC}"
echo -e "Total requests sent: ~$((DURATION * RATE))"
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
