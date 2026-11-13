# Serverless Functions & Scale-to-Zero (KEDA HTTP Add-on)

## Overview & Architecture

Yggdrasil implements an on-premise, self-hosted equivalent to **AWS Lambda** by pairing **KEDA (Kubernetes Event-driven Autoscaling)** with the **KEDA HTTP Add-on** and **Envoy Gateway (Bifrost)**.

This architecture enables:
- **True Scale-to-Zero**: Workloads consume 0 CPU, 0 memory, and 0 pods when idle.
- **Event-Driven HTTP Scale-Up**: Cold requests are held and buffered in milliseconds by the KEDA interceptor proxy while KEDA scales the target deployment from 0 to 1+.
- **Sub-Millisecond Warm Invocations**: Once warmed, traffic flows through directly without cold-start latency.
- **Automatic Scaledown**: Idle timeout automatically terminates function pods back to zero replicas.
- **Cloud-Native Ingress**: Requests enter through Envoy Gateway (`bifrost`) via Gateway API `HTTPRoute` and `ReferenceGrant`.

```
                                  [ Client Request ]
                                          |
                                          v  (Host: fn.yggdrasil.local)
                             +--------------------------+
                             |   Envoy Gateway (Bifrost)|
                             +-------------+------------+
                                           |  (HTTPRoute)
                                           v
                             +--------------------------+
                             | KEDA HTTP Interceptor    |  (keda-system:8080)
                             | - Buffers incoming req   |
                             | - Increments queue depth |
                             +-------------+------------+
                                           |
                    +----------------------+----------------------+
                    | (Pending Requests > 0)                      | (Proxied once ready)
                    v                                             v
     +------------------------------+             +-------------------------------+
     | KEDA External Scaler & KPA   |             | Function Workload Pod         |
     | - Detects traffic event      |             | - Scale-to-Zero: min 0, max 5 |
     | - Scales Deployment: 0 -> 1  |             | - Header: X-Keda-Cold-Start   |
     +------------------------------+             +-------------------------------+
```

---

## Component Manifests

| Path | Purpose |
| :--- | :--- |
| `infrastructure/base/keda/http-add-on-helmrelease.yaml` | Flux `HelmRelease` deploying operator, external-scaler, and interceptor |
| `apps/base/serverless/echo-function.yaml` | Sample serverless microservice (`Deployment`, `Service`, `HTTPScaledObject`) |
| `apps/base/serverless/httproute.yaml` | Envoy Gateway `HTTPRoute` directing `fn.yggdrasil.local` to the interceptor |
| `apps/base/serverless/referencegrant.yaml` | Gateway API `ReferenceGrant` allowing `web-system` to route to `keda-system` |
| `scripts/mirror-keda-http-to-harbor.sh` | Harbor mirroring utility for KEDA HTTP images and Helm chart |

---

## Authoring a Serverless Function (`HTTPScaledObject`)

To make any standard container or microservice operate as a serverless Lambda function, define an `HTTPScaledObject`:

```yaml
apiVersion: http.keda.sh/v1alpha1
kind: HTTPScaledObject
metadata:
  name: my-function
  namespace: web-system
spec:
  hosts:
    - my-fn.yggdrasil.local
  scaleTargetRef:
    name: my-function
    kind: Deployment
    apiVersion: apps/v1
    service: my-function
    port: 8080
  replicas:
    min: 0               # Scale to absolute ZERO when idle
    max: 10              # Maximum concurrency limit
  scaledownPeriod: 30    # Seconds of silence before scaling back to 0
  targetPendingRequests: 100
```

### Response Headers
When invoked, the interceptor decorates responses with telemetry:
- `X-Keda-Http-Cold-Start: true`: The request was buffered while a pod was dynamically spun up.
- `X-Keda-Http-Cold-Start: false`: Served immediately by an active, warm pod.

---

## Verification & Testing

### 1. Check Idle Scale-to-Zero State
```bash
kubectl -n web-system get deployment echo-fn
# Output: echo-fn   0/0     0            0
```

### 2. Invoke the Function (Cold Start)
```bash
curl -I -H "Host: fn.yggdrasil.local" https://yggdrasil.local/
# Response:
# HTTP/1.1 200 OK
# x-keda-http-cold-start: true
```

### 3. Verify Active Pod
```bash
kubectl -n web-system get pods -l app=echo-fn
# Output: echo-fn-79566c68f4-fqn7k   1/1     Running
```

### 4. Automatic Scale-Back to Zero
After 30 seconds of inactivity:
```bash
kubectl -n web-system get deployment echo-fn
# Output: echo-fn   0/0     0            0
```
