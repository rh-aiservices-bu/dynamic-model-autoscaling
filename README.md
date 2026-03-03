# Dynamic Model Autoscaling with KEDA

AI model deployment and autoscaling on OpenShift using KEDA, KServe, and vLLM.

## Prerequisites

- OpenShift AI cluster with GPU nodes
- Cluster admin access

## Quick Start

### 1. Install KEDA Operator

```bash
oc create namespace openshift-keda
oc label namespace openshift-keda openshift.io/cluster-monitoring=true
helm install keda helm/keda-operator/ -n openshift-keda
```

### 2. Enable User Workload Monitoring

```bash
helm install uwm helm/uwm/ -n openshift-monitoring
```

### 3. Create Project

```bash
oc new-project autoscaling-demo
```

### 4. Setup KEDA Authentication (Required for Autoscaling)

```bash
# Create ServiceAccount for KEDA to access Thanos metrics
oc create sa keda-prometheus-sa -n autoscaling-demo

# Create ServiceAccount token secret
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: keda-prometheus-sa-token
  namespace: autoscaling-demo
  annotations:
    kubernetes.io/service-account.name: keda-prometheus-sa
type: kubernetes.io/service-account-token
EOF

# Grant cluster-monitoring-view role (required for Thanos access)
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z keda-prometheus-sa -n autoscaling-demo
```

### 5. Deploy Model with Helm

```bash
# Granite 3.3-8B with KEDA autoscaling
helm install granite3-3-8b helm/granite3.3-8b/ \
  --set keda.enabled=true \
  --set monitoring.enabled=true \
  -n autoscaling-demo

# OR Llama 3.2-3B with KEDA autoscaling
helm install llama3-2-3b helm/llama3.2-3b/ \
  --set keda.enabled=true \
  --set monitoring.enabled=true \
  -n autoscaling-demo
```

### 6. Verify Autoscaling

```bash
# Check ScaledObject
oc get scaledobject -n autoscaling-demo

# Check HPA (should show metrics like "0/3 (avg)")
oc get hpa -n autoscaling-demo

# Check pods
oc get pods -n autoscaling-demo
```

## Architecture

- **vLLM**: High-performance LLM inference server
- **KServe**: Model serving with InferenceService
- **KEDA**: Event-driven autoscaling based on vLLM metrics
- **Prometheus/Thanos**: Metrics collection and querying

See individual chart READMEs for detailed configuration:
- [granite3.3-8b/KEDA-README.md](helm/granite3.3-8b/KEDA-README.md)
- [llama3.2-3b/KEDA-README.md](helm/llama3.2-3b/KEDA-README.md)