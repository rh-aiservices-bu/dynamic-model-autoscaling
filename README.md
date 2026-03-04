# Dynamic Model Autoscaling with KEDA

Metrics-based autoscaling for LLM inference services on OpenShift AI, helping you efficiently manage GPU resources, lower operational costs, and ensure performance requirements are met.

This project uses the OpenShift Custom Metrics Autoscaler (CMA), based on Kubernetes Event-driven Autoscaling (KEDA), to autoscale KServe InferenceServices in RawDeployment mode. It leverages vLLM runtime metrics available in OpenShift Monitoring to trigger scaling, such as:

- **Request queue depth** (`vllm:num_requests_waiting`)
- **Active requests** (`vllm:num_requests_running`)
- **KV Cache utilization**
- **Time to First Token (TTFT)**

## Architecture

![Arch](./assets/images/keda1.png)

- **vLLM**: High-performance LLM inference server exposing Prometheus metrics
- **KServe**: Model serving with InferenceService (RawDeployment mode)
- **KEDA**: Event-driven autoscaling triggered by vLLM metrics
- **Prometheus/Thanos**: Metrics collection via OpenShift User Workload Monitoring

### How It Works

1. vLLM exposes metrics like `num_requests_waiting` and `num_requests_running`
2. Prometheus scrapes these metrics via ServiceMonitor
3. KEDA queries Thanos and scales the deployment based on configured thresholds
4. Scale-up is triggered within ~30-60 seconds; scale-down after ~5 minutes cooldown

## Prerequisites

- OpenShift AI cluster with GPU nodes
- Cluster admin access

## Installation

### Step 1: Install KEDA Operator

```bash
oc create namespace openshift-keda
oc label namespace openshift-keda openshift.io/cluster-monitoring=true
helm install keda-operator helm/keda-operator/ -n openshift-keda
```

### Step 2: Enable User Workload Monitoring

```bash
helm install uwm helm/uwm/ -n openshift-monitoring
```

### Step 3: Configure KEDA Controller

```bash
helm install keda helm/keda/ -n openshift-keda
```

### Step 4: Deploy Model (choose one)

**Option A: Llama 3.2-3B**

```bash
export NAMESPACE=llm
oc new-project $NAMESPACE
helm install llama3-2-3b helm/llama3.2-3b/ \
  --set keda.enabled=true \
  --set inferenceService.maxReplicas=2 \
  -n $NAMESPACE
```

**Option B: Granite 3.3-8B**

```bash
export NAMESPACE=llm
oc new-project $NAMESPACE
helm install granite3-3-8b helm/granite3.3-8b/ \
  --set keda.enabled=true \
  --set inferenceService.maxReplicas=2 \
  -n $NAMESPACE
```

## Demo

### Verify Autoscaling Setup

```bash
# Check all KEDA resources
oc get scaledobject,hpa,pods -n $NAMESPACE

# Check InferenceService status
oc get inferenceservice -n $NAMESPACE
```

![Keda2](./assets/images/keda2.png)

### Run Load Test

Generate load to trigger autoscaling:

```bash
DURATION=60 RATE=20 NAMESPACE=$NAMESPACE ./scripts/basic-load-test.sh
```

```
════════════════════════════════════════════════════════════════════════════════╗
║  KEDA Autoscaling Load Test - vLLM Metrics Monitor                             ║
╠════════════════════════════════════════════════════════════════════════════════╣
║  Endpoint:    https://llama3-2-3b-llm.apps.XXXX/v1
║  Model:       llama3-2-3b
║  Namespace:   llm
║  Deployment:  llama3-2-3b-predictor
║  Duration:    60s @ 20 req/s
║  Max Tokens:  500 (longer = more load)
╚════════════════════════════════════════════════════════════════════════════════╝

Initial State:
  Metrics: Running=0.0, Waiting=0.0, Success=582
  Pods: 1
  Autoscaler: keda-hpa-llama3-2-3b-predictor   Deployment/llama3-2-3b-predictor   0/2 (avg)   1     3     1     28m

Starting sustained load test...

┌──────────┬────────────┬────────────┬────────────┬──────────┬────────────────────┐
│ Time     │ Running    │ Waiting    │ Success    │ Pods     │ Requests Sent      │
├──────────┼────────────┼────────────┼────────────┼──────────┼────────────────────┤
│       0s │       40.0 │        0.0 │        582 │        1 │                  0 │
│       8s │      180.0 │        0.0 │        582 │        1 │                160 │
│      15s │      256.0 │       24.0 │        642 │        1 │                300 │
│      23s │      256.0 │      104.0 │        702 │        1 │                460 │
│      31s │      247.0 │      153.0 │        822 │        1 │                620 │
│      39s │      256.0 │      108.0 │        918 │        3 │                780 │
│      47s │      256.0 │       28.0 │        998 │        3 │                940 │
│      55s │      164.0 │        0.0 │       1106 │        3 │               1100 │
│      63s │        0.0 │        0.0 │       1230 │        3 │               1260 │
└──────────┴────────────┴────────────┴────────────┴──────────┴────────────────────┘
```

### Check the Metrics

Query vLLM metrics in the OpenShift Console (Observe → Metrics):

```promql
# Requests waiting in queue (triggers scale-up when > threshold)
sum(vllm:num_requests_waiting{model_name="llama3-2-3b"})

# Active requests being processed
sum(vllm:num_requests_running{model_name="llama3-2-3b"})
```

![Keda3](./assets/images/keda3.png)

### Watch Scaling in Action

```bash
# Watch pod scaling in real-time
oc get pods -n $NAMESPACE -w
```

![Keda3](./assets/images/keda4.png)

Scaled from 1 → 3 pods based on `vllm:num_requests_waiting` exceeding the threshold (default: 2).

Expected behavior:
- **Scale-up**: Pods increase from 1 to 3 within ~30-60 seconds when request queue grows
- **Scale-down**: Pods return to 1 after ~5 minutes cooldown when load stops

## Scale-to-Zero with KEDA HTTP Add-on

For cost savings, you can enable scale-to-zero using the KEDA HTTP Add-on. This keeps the model at 0 replicas when idle and scales up on first request.

### Install HTTP Add-on

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install http-add-on kedacore/keda-add-ons-http -n openshift-keda
```

### Deploy Model with Scale-to-Zero

```bash
# Get route hostname (deploy first without httpAddon to get the hostname)
helm install llama3-2-3b helm/llama3.2-3b/ -n $NAMESPACE
ROUTE_HOST=$(oc get route llama3-2-3b -n $NAMESPACE -o jsonpath='{.spec.host}')

# Upgrade with HTTP Add-on enabled
helm upgrade llama3-2-3b helm/llama3.2-3b/ \
  --set keda.enabled=true \
  --set httpAddon.enabled=true \
  --set httpAddon.host=$ROUTE_HOST \
  -n $NAMESPACE
```

### Verify Scale-to-Zero

```bash
# Check HTTPScaledObject and deployment
oc get httpscaledobject,deployment -n $NAMESPACE

# After 5 min idle, deployment should show 0/0 replicas
# Send a request to trigger scale-up from 0 to 1
curl -sk https://$ROUTE_HOST/v1/models
```

**Note**: First request after scale-to-zero takes 60-90 seconds while the model loads.