# KEDA HTTP Add-on for OpenShift

This chart documents the installation of the KEDA HTTP Add-on for enabling scale-to-zero HTTP workloads.

## Overview

The HTTP Add-on provides:
- **Interceptor**: Always-on proxy that queues requests when no backends exist
- **Scaler**: Reports HTTP queue metrics to KEDA
- **Operator**: Watches HTTPScaledObject CRDs

## Prerequisites

- KEDA operator installed (`helm/keda-operator`)
- KEDA controller configured (`helm/keda`)
- OpenShift 4.12+

## Installation

The HTTP Add-on is installed from the upstream KEDA Helm repository:

```bash
# Add KEDA Helm repo
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# Install HTTP Add-on
helm install http-add-on kedacore/keda-add-ons-http -n openshift-keda
```

## Verify Installation

```bash
# Check pods
oc get pods -n openshift-keda | grep http

# Expected output:
# keda-add-ons-http-controller-manager-xxx   Running
# keda-add-ons-http-interceptor-xxx          Running
# keda-add-ons-http-external-scaler-xxx      Running
```

## Usage with Model Charts

Enable HTTP Add-on in model deployments for scale-to-zero:

```bash
# Get your route hostname
ROUTE_HOST=$(oc get route llama3-2-3b -n llm -o jsonpath='{.spec.host}')

helm upgrade llama3-2-3b ../llama3.2-3b/ \
  --set keda.enabled=true \
  --set httpAddon.enabled=true \
  --set httpAddon.host=$ROUTE_HOST \
  -n llm
```

## How It Works

1. Route points to the HTTP Add-on interceptor (always running)
2. Interceptor queues incoming requests
3. Interceptor reports queue metrics to KEDA scaler
4. KEDA scales deployment 0→N based on queue depth
5. Once pods are ready, interceptor forwards queued requests

## Compatibility

| HTTP Add-On | KEDA | Kubernetes |
|-------------|------|------------|
| 0.8.0 | v2.14 | v1.27-v1.29 |
| 0.9.0 | v2.16 | v1.29-v1.31 |
| 0.10.0 | v2.16 | v1.20-v1.32 |

## References

- [KEDA HTTP Add-on Documentation](https://kedacore.github.io/http-add-on/)
- [Installation Guide](https://kedacore.github.io/http-add-on/install.html)
- [HTTPScaledObject Reference](https://kedacore.github.io/http-add-on/reference/v0.8.0/http_scaled_object/)
