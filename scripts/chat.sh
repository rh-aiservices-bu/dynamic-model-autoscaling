#!/bin/bash
# Streaming chat client for vLLM endpoints
# Sends a chat completion request and displays tokens as they stream in,
# exactly like a chat client would.
#
# Usage: ./scripts/chat.sh [-H HOST] [-m MODEL] [-n NAMESPACE] [PROMPT]
# Examples:
#   ./scripts/chat.sh -n autoscaling-keda-http-addon "What is Kubernetes?"
#   ./scripts/chat.sh -H llama3-2-3b.apps.example.com "Explain containers"
#   ./scripts/chat.sh                                  # defaults to "Say hello"

set -euo pipefail

MODEL="llama3-2-3b"
HOST=""
NAMESPACE=""
PROMPT="Say hello"

usage() {
    echo "Usage: $(basename "$0") [-H HOST] [-m MODEL] [-n NAMESPACE] [PROMPT]"
    echo ""
    echo "Options:"
    echo "  -H HOST       Route hostname (auto-detected from NAMESPACE if omitted)"
    echo "  -m MODEL      Model name (default: llama3-2-3b)"
    echo "  -n NAMESPACE  Namespace to auto-detect route from"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") -n autoscaling-keda-http-addon \"What is Kubernetes?\""
    echo "  $(basename "$0") -H llama3-2-3b.apps.example.com \"Explain containers\""
    exit 1
}

while getopts "H:m:n:h" opt; do
    case $opt in
        H) HOST="$OPTARG" ;;
        m) MODEL="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -gt 0 ]] && PROMPT="$1"

# Auto-detect route host
if [[ -z "$HOST" ]]; then
    NS_FLAG=()
    [[ -n "$NAMESPACE" ]] && NS_FLAG=(-n "$NAMESPACE")
    HOST=$(oc get route "${NS_FLAG[@]}" -l "app.kubernetes.io/name=$MODEL" \
        -o jsonpath='{.items[0].spec.host}' 2>/dev/null) || {
        echo "Error: Could not detect route. Use -H to specify the hostname." >&2
        exit 1
    }
fi

# Build JSON payload safely
PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --arg prompt "$PROMPT" \
    '{model: $model, stream: true, messages: [{role: "user", content: $prompt}]}')

# Stream and display content token by token
curl -Nsk "https://$HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" | while IFS= read -r line; do
    # Strip carriage return and skip empty lines
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue

    # Strip "data: " prefix
    data="${line#data: }"

    # End of stream
    [[ "$data" == "[DONE]" ]] && break

    # Extract and print content (delta.content may be absent on some chunks)
    content=$(printf '%s' "$data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null) || continue
    [[ -n "$content" ]] && printf '%s' "$content"
done
echo ""
