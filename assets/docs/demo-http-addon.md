# Demo: Scale-to-Zero with KEDA HTTP Add-on

This demo shows how to enable scale-to-zero for LLM inference services using the KEDA HTTP Add-on. When idle, the model scales to 0 replicas (releasing GPU resources), and automatically scales up when requests arrive.

## Prerequisites

- KEDA Operator installed in `openshift-keda` namespace
- User Workload Monitoring enabled
- GPU nodes available

## How It Works

The KEDA HTTP Add-on solves the scale-to-zero problem by providing an always-on interceptor that:

1. **Queues incoming requests** when pods = 0
2. **Reports queue metrics** to KEDA (not Prometheus)
3. **Triggers scale-up** based on queue depth
4. **Forwards requests** once pods are ready

```
With HTTP Add-on:  Request → Route → Interceptor → Queue → KEDA 0→1 → Forward ✓
```

For detailed architecture, see [KEDA HTTP Add-on Architecture](autoscaling-keda-http-addon.md).

## Step 1: Install HTTP Add-on

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# Install with extended timeouts for LLM cold starts
helm install http-add-on kedacore/keda-add-ons-http -n openshift-keda \
  --set interceptor.replicas.waitTimeout=180s \
  --set interceptor.responseHeaderTimeout=180s
```

Verify installation:

```bash
oc get pods -n openshift-keda | grep http
```

Expected output:
```
keda-add-ons-http-controller-manager-xxx   1/1     Running
keda-add-ons-http-interceptor-xxx          1/1     Running
keda-add-ons-http-scaler-xxx               1/1     Running
```

## Step 2: Deploy Model with Scale-to-Zero

```bash
export NAMESPACE=llm
oc new-project $NAMESPACE

# Deploy with HTTP Add-on enabled
# First, get the route hostname pattern
ROUTE_HOST="llama3-2-3b-keda-${NAMESPACE}.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"

helm install llama3-2-3b helm/llama3.2-3b/ \
  --set keda.enabled=true \
  --set httpAddon.enabled=true \
  --set httpAddon.host=$ROUTE_HOST \
  --set httpAddon.minReplicas=0 \
  --set httpAddon.maxReplicas=1 \
  --set httpAddon.scaledownPeriod=60 \
  -n $NAMESPACE
```

## Step 3: Verify Deployment

```bash
# Check HTTPScaledObject
oc get httpscaledobject -n $NAMESPACE

# Expected output:
# NAME          TARGETWORKLOAD                            MINREPLICAS   MAXREPLICAS   READY
# llama3-2-3b   apps/v1/Deployment/llama3-2-3b-predictor  0             3             True

# Check current pods (should be 0 after scaledownPeriod)
oc get pods -n $NAMESPACE

# Check the route
oc get route -n $NAMESPACE
```

## Step 4: Test Scale-to-Zero

### Watch the scaling

Open a terminal to watch pods:

```bash
oc get pods -n $NAMESPACE -w
```

### Trigger scale-up from zero

In another terminal, send a request:

```bash
ROUTE_HOST=$(oc get route llama3-2-3b-keda -n $NAMESPACE -o jsonpath='{.spec.host}')

# This will take 60-90 seconds on first request (cold start)
time curl -sk "https://$ROUTE_HOST/v1/models"
```

You should see in the watch terminal:
```
NAME                                    READY   STATUS    RESTARTS   AGE
llama3-2-3b-predictor-xxx-xxx           0/2     Pending   0          0s
llama3-2-3b-predictor-xxx-xxx           0/2     ContainerCreating   0          1s
llama3-2-3b-predictor-xxx-xxx           1/2     Running   0          30s
llama3-2-3b-predictor-xxx-xxx           2/2     Running   0          65s
```

### Verify scale-down

After 60 seconds of no traffic (configurable via `scaledownPeriod`):

```bash
# Watch pods scale down
oc get pods -n $NAMESPACE -w

# After ~60s idle:
# llama3-2-3b-predictor-xxx-xxx   2/2     Terminating   0          2m
# (no pods)
```

## Step 5: Load Test with Scale-to-Zero

```bash
# Generate load to trigger scaling
DURATION=60 RATE=10 NAMESPACE=$NAMESPACE ./scripts/basic-load-test.sh

# Watch scaling behavior
oc get pods -n $NAMESPACE -w
```

## Configuration Options

| Parameter | Default | Description |
|-----------|---------|-------------|
| `httpAddon.enabled` | `false` | Enable HTTP Add-on for scale-to-zero |
| `httpAddon.host` | `""` | Route hostname (required) |
| `httpAddon.minReplicas` | `0` | Minimum replicas (0 for scale-to-zero) |
| `httpAddon.maxReplicas` | `3` | Maximum replicas |
| `httpAddon.scaledownPeriod` | `300` | Seconds to wait before scaling down |
| `httpAddon.targetValue` | `2` | Requests per replica threshold |

## Comparison: Prometheus vs HTTP Add-on

| Feature | Prometheus KEDA | HTTP Add-on |
|---------|-----------------|-------------|
| Scaling range | 1→N | 0→N |
| Scale-to-zero | No | Yes |
| Metrics source | vLLM Prometheus | Interceptor queue |
| Cold start handling | N/A | Request queuing |
| GPU cost when idle | Always 1 GPU | 0 GPUs |

## Troubleshooting

### Request timeout on cold start

If requests timeout before the pod is ready, increase the interceptor timeout:

```bash
helm upgrade http-add-on kedacore/keda-add-ons-http -n openshift-keda \
  --set interceptor.replicas.waitTimeout=180s \
  --set interceptor.responseHeaderTimeout=180s
```

Also ensure the Route has HAProxy timeout annotation (automatically set by the Helm chart):

```yaml
annotations:
  haproxy.router.openshift.io/timeout: 180s
```

### Route returns 503

Check if the interceptor proxy service exists:

```bash
oc get svc -n $NAMESPACE | grep interceptor
oc get endpoints -n $NAMESPACE | grep interceptor
```

### HTTPScaledObject not ready

Check the HTTP Add-on operator logs:

```bash
oc logs -n openshift-keda -l app.kubernetes.io/name=keda-add-ons-http-controller-manager
```

## Cleanup

```bash
helm uninstall llama3-2-3b -n $NAMESPACE
oc delete project $NAMESPACE
```
