# Demo: Cold Start Streaming Callback with KEDA HTTP Add-on

When using scale-to-zero, clients sending streaming requests (e.g., chat completions with `"stream": true`) wait silently for 60-90 seconds while the model pod starts. The cold start streaming callback feature solves this by immediately sending SSE events to keep the client informed and the connection alive.

## How It Works

A custom build of the KEDA HTTP Add-on interceptor adds a `coldStartStreamingCallback` field to the HTTPScaledObject spec. When a streaming request arrives during a cold start:

1. **Immediately** (~100ms): the interceptor sends an SSE event with your configured message
2. **Every N seconds**: empty keepalive events are sent to prevent proxy/load balancer timeouts
3. **When the model is ready**: the real vLLM response streams through seamlessly

```
Without callback:  Request → Interceptor → [60-90s silence] → Response
With callback:     Request → Interceptor → SSE "loading..." → keepalives → Response
```

Non-streaming requests (e.g., `GET /v1/models`) are unaffected and behave as before.

## Prerequisites

- KEDA Operator installed in `openshift-keda` namespace
- Scale-to-zero already working (see [Demo: Scale-to-Zero](demo-http-addon.md))

## Step 1: Install CRDs and RBAC

The custom interceptor introduces a new `InterceptorRoute` CRD and the `coldStartStreamingCallback` field in HTTPScaledObject. These must be in place **before** the interceptor pod starts.

Clone the fork and apply the updated CRDs:

```bash
git clone -b feat/llm-callback https://github.com/rh-aiservices-bu/http-add-on.git
cd http-add-on

oc apply -f config/crd/bases/http.keda.sh_httpscaledobjects.yaml
oc apply -f config/crd/bases/http.keda.sh_interceptorroutes.yaml
```

The upstream Helm chart's RBAC doesn't cover the new `InterceptorRoute` resource. Grant the interceptor service account access:

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: keda-add-ons-http-interceptor-interceptorroutes
rules:
  - apiGroups: ["http.keda.sh"]
    resources: ["interceptorroutes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: keda-add-ons-http-interceptor-interceptorroutes
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: keda-add-ons-http-interceptor-interceptorroutes
subjects:
  - kind: ServiceAccount
    name: keda-add-ons-http-interceptor
    namespace: openshift-keda
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: keda-add-ons-http-interceptorroute
rules:
- apiGroups: ["http.keda.sh"]
  resources: ["interceptorroutes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["http.keda.sh"]
  resources: ["interceptorroutes/status"]
  verbs: ["get", "update", "patch"]
- apiGroups: ["http.keda.sh"]
  resources: ["interceptorroutes/finalizers"]
  verbs: ["update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: keda-add-ons-http-interceptorroute
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: keda-add-ons-http-interceptorroute
subjects:
- kind: ServiceAccount
  name: keda-add-ons-http
  namespace: openshift-keda
EOF
```

## Step 2: Install HTTP Add-on with Callback-Enabled Interceptor

Pre-built images with callback support are available at `quay.io/rh-aiservices-bu/http-add-on-{interceptor,scaler,operator}`, tagged `callback-latest`.

The upstream Helm chart packages CRDs as templates, so a normal `helm install` would overwrite the custom CRDs from Step 1. To prevent this, pull the chart locally, strip its CRD templates, and install from the modified copy:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

CHART_DIR=$(mktemp -d)
helm pull kedacore/keda-add-ons-http --untar --untardir "$CHART_DIR"

# Remove CRD templates so Helm doesn't overwrite the custom CRDs from Step 1
find "$CHART_DIR" -name '*crd*' -delete

helm upgrade --install http-add-on "$CHART_DIR/keda-add-ons-http" -n openshift-keda \
  --skip-crds \
  --set images.interceptor=quay.io/rh-aiservices-bu/http-add-on-interceptor \
  --set images.scaler=quay.io/rh-aiservices-bu/http-add-on-scaler \
  --set images.operator=quay.io/rh-aiservices-bu/http-add-on-operator \
  --set images.tag=callback-latest \
  --set interceptor.replicas.waitTimeout=600s \
  --set interceptor.responseHeaderTimeout=600s \
  --set podSecurityContext.fsGroup=null \
  --set podSecurityContext.supplementalGroups=null

rm -rf "$CHART_DIR"
```

> **Note**: The `--skip-crds` flag handles CRDs in the chart's `crds/` directory, while the `find -delete` handles CRDs packaged as templates. Together they ensure Helm never touches the custom CRDs.

> **Note**: The `waitTimeout` and `responseHeaderTimeout` must be long enough for the model to finish loading. If the timeout expires before the model is ready, the callback closes the connection, concurrency drops to 0, and KEDA scales the pod back down — killing it before it finishes loading. 600s is a safe default; increase for larger models.

> **Note**: The `podSecurityContext` overrides clear the upstream chart's default `fsGroup: 1000`, which OpenShift's `restricted-v2` SCC rejects. This lets OpenShift assign the namespace's allocated group automatically.

Verify the custom CRD is intact and the interceptor is running the correct image:

```bash
oc get crd httpscaledobjects.http.keda.sh -o yaml | grep coldStart

oc get pods -n openshift-keda -l app.kubernetes.io/name=http-add-on,app.kubernetes.io/component=interceptor \
  -o jsonpath='{.items[0].spec.containers[0].image}'
```

## Step 3: Deploy Model with Callback Enabled

> **Note**: If you already have a standard KEDA deployment of the same model (e.g., `llama3-2-3b` in `autoscaling-keda`), uninstall it first. The Helm chart creates cluster-scoped resources (ClusterRoles) tied to the release name, so two releases with the same name in different namespaces will conflict.
>
> ```bash
> helm uninstall llama3-2-3b -n autoscaling-keda
> ```

> **Important**: Before deploying, review the chart's `values.yaml` and adapt values to your environment. In particular, `tolerations` must match your GPU node configuration (e.g., the default tolerates `nvidia.com/gpu=l40-gpu`, which will need to be changed for other GPU types).

```bash
export NAMESPACE=autoscaling-keda-http-addon
oc new-project $NAMESPACE

RELEASE_NAME=llama3-2-3b
ROUTE_HOST="${RELEASE_NAME}-keda-${NAMESPACE}.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"

helm install $RELEASE_NAME helm/llama3.2-3b/ \
  --set keda.enabled=true \
  --set httpAddon.enabled=true \
  --set httpAddon.host=$ROUTE_HOST \
  --set httpAddon.minReplicas=0 \
  --set httpAddon.maxReplicas=1 \
  --set httpAddon.scaledownPeriod=120 \
  --set httpAddon.coldStartCallback.enabled=true \
  -n $NAMESPACE
```

Verify the HTTPScaledObject includes the callback configuration:

```bash
oc get httpscaledobject $RELEASE_NAME -n $NAMESPACE -o yaml | grep -A3 coldStart
```

Expected output:
```yaml
  coldStartStreamingCallback:
    intervalSeconds: 5
    keepaliveMessage: "."
    message: "Model is waking up, hold on..."
```

## Step 4: Test the Callback

### Wait for scale-to-zero

```bash
oc get pods -n $NAMESPACE -w
# Wait until no pods are running
```

### Send a streaming request

A helper script is provided to display streamed tokens like a chat client:

```bash
./scripts/chat.sh -n $NAMESPACE "Say hello"
```

Or use curl directly to see the raw SSE events:

```bash
ROUTE_HOST=$(oc get route -n $NAMESPACE -l app.kubernetes.io/name=llama3-2-3b \
  -o jsonpath='{.items[0].spec.host}')

# -N disables output buffering so you see SSE events in real time
curl -Nsk https://$ROUTE_HOST/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3-2-3b",
    "stream": true,
    "messages": [{"role": "user", "content": "Say hello"}]
  }'
```

### What you should see

1. **Immediately** (within ~100ms): the first SSE event with your loading message
```
data: {"id":"keda-cold-start","object":"chat.completion.chunk","created":1713264000,"model":"system","choices":[{"index":0,"delta":{"content":"Model is waking up, hold on..."},"finish_reason":null}]}
```

2. **Every 5 seconds**: empty keepalive events (keeps the connection alive through proxies/load balancers)

3. **After 60-90s** (when the model pod is ready): the real response from vLLM streams through seamlessly
```
data: {"id":"chatcmpl-xxx","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},...}]}
...
data: [DONE]
```

## Step 5: Verify Non-Streaming Requests

Non-streaming requests should behave exactly as before (block silently, no SSE events):

```bash
curl -sk --max-time 600 https://$ROUTE_HOST/v1/models
```

## Configuration Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `httpAddon.coldStartCallback.enabled` | `false` | Enable SSE callback during cold starts |
| `httpAddon.coldStartCallback.message` | `"Model is waking up, hold on..."` | Message sent in the initial SSE event |
| `httpAddon.coldStartCallback.keepaliveMessage` | `""` | Content of keepalive SSE events |
| `httpAddon.coldStartCallback.intervalSeconds` | `5` | Seconds between keepalive events |

## Comparison: Standard vs Callback HTTP Add-on

| Behavior | Standard HTTP Add-on | With Callback |
|----------|---------------------|---------------|
| Non-streaming cold start | Silent wait | Silent wait (unchanged) |
| Streaming cold start | Silent wait | Immediate SSE feedback + keepalives |
| Connection timeout risk | High (60-90s silence) | Low (periodic keepalives) |
| Client UX | No feedback during load | "Model is loading" message |
| Component images | Upstream `kedacore` | All three from `rh-aiservices-bu/http-add-on-{interceptor,scaler,operator}` |
| CRD changes | None | Updated CRDs required |

## Troubleshooting

### No SSE events received during cold start

- Verify the custom interceptor image is running: check the image tag on the interceptor pod in `openshift-keda`
- Verify the CRDs were updated: `oc get crd httpscaledobjects.http.keda.sh -o yaml | grep coldStart`
- Verify the HTTPScaledObject has the callback field: `oc get httpscaledobject -n $NAMESPACE -o yaml`

### Keepalive events not preventing timeouts

Increase the HAProxy timeout annotation on the Route (set automatically by the Helm chart to `600s`):

```yaml
annotations:
  haproxy.router.openshift.io/timeout: 600s
```

Or reduce `intervalSeconds` to send keepalives more frequently.

### HTTPScaledObject missing coldStartStreamingCallback after deploy

If the Helm chart was installed without stripping CRD templates (see Step 2), the upstream CRD overwrites the custom one and the API server prunes the unknown field silently. Re-apply the CRD from the fork and patch the existing object:

```bash
oc patch httpscaledobject $RELEASE_NAME -n $NAMESPACE --type=merge -p '
{
  "spec": {
    "coldStartStreamingCallback": {
      "message": "Model is waking up, hold on...",
      "keepaliveMessage": ".",
      "intervalSeconds": 5
    }
  }
}'
```

## Known Issues and Fixes

### Scaling metric compatibility

The custom interceptor (built from the `feat/llm-callback` branch) no longer computes RPS (requests per second) internally. Instead, it reports a raw monotonic `RequestCount` counter, and the new scaler code computes RPS from deltas between polls. This change was introduced in commit `81222e4` (refactor: move RPS calculation from interceptor to scaler).

**Impact**: If the HTTPScaledObject uses `scalingMetric.requestRate`, the upstream v0.13.0 scaler reads `RPS` from the interceptor's `/queue` endpoint, which is now always `0`. KEDA reports: `Scaling is not performed because triggers are not active`.

**Fix**: Either switch to concurrency-based scaling (recommended for LLM workloads), or build all components (interceptor, scaler, operator) from the same branch.

Using concurrency-based scaling:

```yaml
scalingMetric:
  concurrency:
    targetValue: 1
```

Concurrency is a better fit for LLM inference: a single in-flight request holds `Concurrency: 1` for the entire duration (cold start + inference), keeping the trigger active. With rate-based scaling, a single request registers as ~0.017 RPS over a 1-minute window, which is unreliable for scale-from-zero.

### scaleTargetRef.port must match the container port

The `scaleTargetRef.port` in the HTTPScaledObject must be set to the port the inference container actually listens on (e.g., `8080` for vLLM), **not** the Kubernetes Service port.

The interceptor builds the upstream proxy URL directly from `scaleTargetRef.port` (see `interceptor/middleware/routing.go:131`), bypassing the Service's `port`/`targetPort` mapping. A mismatch causes silent connection failures — the interceptor connects to the wrong port on the pod, and the client sees an empty response or connection drop.

```yaml
# Correct — matches the port vLLM listens on
scaleTargetRef:
  port: 8080
  service: llama3-2-3b-predictor

# Wrong — matches the Service port, not the container port
scaleTargetRef:
  port: 80
  service: llama3-2-3b-predictor
```
