# KEDA Prometheus-based Autoscaling (1→N)

```
┌─────────────────┐    scrapes     ┌─────────────────┐
│   vLLM Pod      │ ◀──────────────│   Prometheus    │
│ (metrics:8080)  │                │ (User Workload) │
└─────────────────┘                └────────┬────────┘
                                            │
                                   ┌────────▼────────┐
                                   │ Thanos Querier  │
                                   │ (aggregates)    │
                                   └────────┬────────┘
                                            │
                                            │ queries
                                            ▼
┌─────────────────┐   creates/    ┌─────────────────┐
│  ScaledObject   │ ─────────────▶│      HPA        │
│                 │   manages     │                 │
└────────┬────────┘               └────────┬────────┘
         │                                 │
         │ references                      │ scales
         ▼                                 ▼
┌─────────────────┐               ┌─────────────────┐
│ TriggerAuth     │               │   Deployment    │
│ (bearer token)  │               │  (1 → N pods)   │
└─────────────────┘               └─────────────────┘
```

## Step 1: vLLM Exposes Metrics

vLLM exposes Prometheus metrics on port 8080:

```
vllm:num_requests_waiting = 5    # Requests queued
vllm:num_requests_running = 10   # Requests being processed
```

## Step 2: Prometheus Scrapes → Thanos Aggregates

- **Prometheus** (User Workload Monitoring) scrapes metrics via ServiceMonitor
- **Thanos Querier** provides a unified query endpoint across all Prometheus instances

## Step 3: ScaledObject Defines Scaling Rules

ScaledObject tells KEDA what/when/how to scale:
- **What**: Target Deployment
- **When**: Prometheus query exceeds threshold
- **How**: Via TriggerAuthentication credentials

## Step 4: TriggerAuthentication Provides Credentials

KEDA needs a bearer token to query Thanos (protected endpoint). TriggerAuthentication references a Secret containing the token.

## Step 5: KEDA Creates HPA

When ScaledObject is applied, KEDA creates an HPA with external metrics.

## Step 6: HPA Scales Deployment

Every 15 seconds, KEDA queries Thanos. If `vllm:num_requests_waiting > threshold` → HPA scales up.

## Limitation: Can't Scale to Zero

When pods = 0:
- No vLLM running → no metrics
- KEDA sees "no load" → stays at 0
- Incoming request → **503 error**

**Solution**: Use HTTP Add-on with an always-running interceptor.
