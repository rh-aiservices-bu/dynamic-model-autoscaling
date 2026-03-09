#!/bin/bash
# Test scale-to-zero with KEDA HTTP Add-on
# Usage: ./scripts/test-scale-to-zero.sh [namespace] [model]
# Examples:
#   ./scripts/test-scale-to-zero.sh                          # Test all models in default namespace
#   ./scripts/test-scale-to-zero.sh autoscaling-keda-http-addon llama
#   ./scripts/test-scale-to-zero.sh autoscaling-keda-http-addon granite

set -euo pipefail

NAMESPACE="${1:-autoscaling-keda-http-addon}"
MODEL="${2:-all}"  # llama, granite, or all
MAX_WAIT="${MAX_WAIT:-300}"  # Max seconds to wait for cold start

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  KEDA HTTP Add-on Scale-to-Zero Test                                           ║${NC}"
    echo -e "${BLUE}╠════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  Namespace: ${NC}${NAMESPACE}"
    echo -e "${BLUE}║  Model:     ${NC}${MODEL}"
    echo -e "${BLUE}║  Max Wait:  ${NC}${MAX_WAIT}s"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
}

get_route_host() {
    local label="$1"
    oc get route -n "$NAMESPACE" -l "app.kubernetes.io/name=$label" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo ""
}

get_pod_count() {
    oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

test_model() {
    local model_name="$1"
    local label="$2"
    local route_host

    route_host=$(get_route_host "$label")

    if [[ -z "$route_host" ]]; then
        echo -e "${YELLOW}⚠ No route found for $model_name (label: $label)${NC}"
        return 1
    fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Testing: ${NC}${model_name}"
    echo -e "${BLUE}Route:   ${NC}https://${route_host}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check initial state
    local initial_pods
    initial_pods=$(get_pod_count)
    echo -e "${YELLOW}Initial pods in namespace: ${NC}${initial_pods}"

    # Send request and measure time
    echo -e "${YELLOW}Sending request (max wait: ${MAX_WAIT}s)...${NC}"
    local start_time
    start_time=$(date +%s)

    local response
    local exit_code=0
    response=$(curl -sk --max-time "$MAX_WAIT" "https://${route_host}/v1/models" 2>&1) || exit_code=$?

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 && -n "$response" ]]; then
        echo -e "${GREEN}✓ Response received in ${duration}s${NC}"
        echo -e "${GREEN}Models: ${NC}$(echo "$response" | jq -r '.data[].id' 2>/dev/null | tr '\n' ', ' || echo "$response")"

        # Check final pod count
        local final_pods
        final_pods=$(get_pod_count)
        echo -e "${GREEN}Pods after scale-up: ${NC}${final_pods}"
        return 0
    else
        echo -e "${RED}✗ Request failed after ${duration}s (exit code: $exit_code)${NC}"
        echo -e "${RED}Response: ${NC}${response}"
        return 1
    fi
}

print_header

# Check namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: Namespace '$NAMESPACE' does not exist${NC}"
    exit 1
fi

# Check HTTPScaledObjects
echo ""
echo -e "${YELLOW}HTTPScaledObjects in namespace:${NC}"
oc get httpscaledobject -n "$NAMESPACE" 2>/dev/null || echo "None found"

# Check current pods
echo ""
echo -e "${YELLOW}Current pods:${NC}"
oc get pods -n "$NAMESPACE" 2>/dev/null || echo "No pods"

# Test models
case "$MODEL" in
    llama)
        test_model "Llama 3.2-3B" "llama3-2-3b"
        ;;
    granite)
        test_model "Granite 3.3-8B" "granite-3-3-8b"
        ;;
    all)
        test_model "Llama 3.2-3B" "llama3-2-3b" || true
        test_model "Granite 3.3-8B" "granite-3-3-8b" || true
        ;;
    *)
        echo -e "${RED}Unknown model: $MODEL${NC}"
        echo "Usage: $0 [namespace] [llama|granite|all]"
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Final pod status:${NC}"
oc get pods -n "$NAMESPACE" 2>/dev/null || echo "No pods"
echo ""
echo -e "${YELLOW}Tip: Run 'oc get pods -n $NAMESPACE -w' to watch scale-down after ~60s idle${NC}"
