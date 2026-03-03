# KEDA HTTP Add-on Autoscaling (0→N)

```
                                    ┌─────────────────────────────────────────────────────────┐
                                    │                   openshift-keda namespace              │
                                    │                                                         │
┌──────────┐    ┌──────────┐       │  ┌─────────────┐   queue    ┌─────────────┐            │
│  Client  │───▶│  Route   │───────┼─▶│ Interceptor │───metrics─▶│   Scaler    │            │
│          │    │ (*-keda) │       │  │   (proxy)   │            │             │            │
└──────────┘    └──────────┘       │  └──────┬──────┘            └──────┬──────┘            │
                     │             │         │                          │                    │
                     │             │         │ forwards                 │ reports            │
                     │             │         │ (when ready)             │ metrics            │
                     │             │         │                          ▼                    │
                     │             │         │                   ┌─────────────┐            │
                     │             │         │                   │  Operator   │            │
                     │             │         │                   │             │            │
                     │             │         │                   └──────┬──────┘            │
                     │             └─────────┼──────────────────────────┼────────────────────┘
                     │                       │                          │
                     │                       │                          │ creates/manages
                     │                       │                          ▼
                     │                       │                   ┌─────────────────┐
                     │                       │                   │  ScaledObject   │
                     │                       │                   │ (external-push) │
                     │                       │                   └────────┬────────┘
                     │                       │                            │
                     │                       │                            │ scales
                     │                       │                            ▼
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                    llm namespace                                          │
│                                                                                          │
│  ┌──────────────────┐         ┌──────────────────┐         ┌──────────────────┐         │
│  │ HTTPScaledObject │────────▶│   Deployment     │◀────────│ InferenceService │         │
│  │                  │ targets │ (0 → N replicas) │ creates │                  │         │
│  └──────────────────┘         └────────┬─────────┘         └──────────────────┘         │
│                                        │                                                 │
│                                        │ runs                                            │
│                                        ▼                                                 │
│                               ┌──────────────────┐                                      │
│                               │    vLLM Pod      │                                      │
│                               │  (model server)  │                                      │
│                               └──────────────────┘                                      │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Step 1: Client Request Arrives

Request hits the OpenShift Route, which points to the **Interceptor** (not directly to the model).

```yaml
# Route points to interceptor proxy service
spec:
  to:
    kind: Service
    name: llama3-2-3b-interceptor-proxy  # Local proxy → Interceptor
```

## Step 2: Interceptor Queues Request

The Interceptor (always running in `openshift-keda`):
- Holds the request in memory
- Increments queue depth metric
- Reports metrics to the Scaler

## Step 3: Scaler Reports to KEDA Operator

The Scaler aggregates queue metrics and exposes them to KEDA via `external-push` trigger.

## Step 4: Operator Creates ScaledObject

When HTTPScaledObject is deployed, the Operator creates:
- A KEDA ScaledObject with `external-push` trigger
- Configured min/max replicas and scaling thresholds

```yaml
# HTTPScaledObject (user creates)
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
spec:
  hosts: ["llama3-2-3b-llm.apps.cluster.com"]
  scaleTargetRef:
    name: llama3-2-3b-predictor
    kind: Deployment
  replicas:
    min: 0    # Scale to zero!
    max: 3
```

## Step 5: KEDA Scales Deployment 0→1

When queue depth > 0:
1. ScaledObject triggers scale-up
2. Deployment goes from 0 → 1 replicas
3. Pod starts (60-120s for LLM)

## Step 6: Interceptor Forwards Request

Once pod is ready:
1. Interceptor detects healthy endpoint
2. Forwards queued request to vLLM
3. Returns response to client

## Step 7: Scale Down to Zero

After `scaledownPeriod` (default 300s) with no traffic:
1. Queue depth = 0
2. KEDA scales Deployment 1 → 0
3. GPU resources released

## Key Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Route (*-keda) | llm | Entry point, routes to interceptor |
| Interceptor | openshift-keda | Queues requests, reports metrics |
| Scaler | openshift-keda | Aggregates metrics for KEDA |
| Operator | openshift-keda | Manages HTTPScaledObject → ScaledObject |
| HTTPScaledObject | llm | User-defined scaling config |
| ScaledObject | llm | Auto-created by Operator |
| InferenceService | llm | KServe model definition |
| Deployment | llm | vLLM pods (0→N) |

## Why This Works (vs Prometheus-based)

| Prometheus KEDA | HTTP Add-on |
|-----------------|-------------|
| Metrics from vLLM | Metrics from Interceptor |
| No pods = no metrics | Interceptor always running |
| Can't detect traffic at 0 | Queue depth visible at 0 |
| **1→N scaling only** | **0→N scaling** |

## Critical Configuration

### HTTP Add-on Installation (for LLM cold starts)
```bash
helm upgrade http-add-on kedacore/keda-add-ons-http -n openshift-keda \
  --set interceptor.replicas.waitTimeout=180s \
  --set interceptor.responseHeaderTimeout=180s
```

### Route Naming (RHOAI compatibility)
Route must NOT match InferenceService name to avoid deletion by `odh-model-controller`:
```yaml
name: {{ .Release.Name }}-keda  # Not {{ .Release.Name }}
```
