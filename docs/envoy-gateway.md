# Envoy Gateway — Bifrost Edge Layer (`envoy-gateway-system`)

## Purpose
**Envoy Gateway** provides the cloud-native ingress and edge routing layer (*Bifrost*) using the official Kubernetes **Gateway API** (`gateway.networking.k8s.io/v1`), replacing the deprecated `ingress-nginx` controller with CloudFront-style edge compression, rate limiting, and TLS hardening.

## Manifests Location
- `infrastructure/base/gateway/helmrelease.yaml` — Envoy Gateway controller & Gateway API CRDs (`oci://docker.io/envoyproxy/gateway-helm`)
- `apps/base/gateway/gateway.yaml` — `EnvoyProxy`, `GatewayClass` (`bifrost`), and `Gateway` (`bifrost`)
- `apps/base/gateway/edge-policies.yaml` — `BackendTrafficPolicy` & `ClientTrafficPolicy`
- `apps/overlays/kind/gateway-nodeport.yaml` — Kind `NodePort` service mapping (`30080 -> 80`, `30443 -> 443`)

## Important Configuration

1. **Unprivileged Container Ports & Kind NodePorts**
   - Envoy runs as a non-root user inside its pod, translating Gateway listener ports `< 1024` by adding `10000` (`port: 80` → `targetPort: 10080`, `port: 443` → `targetPort: 10443`).
   - `apps/overlays/kind/gateway-nodeport.yaml` exposes `nodePort: 30080` and `nodePort: 30443`, which `kind/cluster-config.yaml` maps to `localhost:80` and `localhost:443`.

2. **Wildcard TLS Termination (`:443`)**
   - The `https` listener on `Gateway/bifrost` terminates TLS using `Secret/bifrost-wildcard-tls` (automatically issued and rotated by `cert-manager` for `yggdrasil.local` and `*.yggdrasil.local`).
   - `allowedRoutes.namespaces.from: All` allows `HTTPRoute` resources in `web-system`, `mail-system`, `git-system`, `registry-system`, `storage-system`, `vault-system`, and `monitoring-system` to attach to the shared edge gateway.

3. **CloudFront-Style Edge Traffic Policies (`edge-policies.yaml`)**
   - **`BackendTrafficPolicy/bifrost-edge-optimizations`**:
     - Enables **Brotli** and **Gzip** edge response compression.
     - Enforces local burst rate limiting (`200 requests/minute`) and a `30s` upstream request timeout.
   - **`ClientTrafficPolicy/bifrost-client-hardening`**:
     - Enforces **TLS 1.2–1.3** (`minVersion: "1.2"`, `maxVersion: "1.3"`) and explicit ALPN (`h2`, `http/1.1`).
     - Terminates malformed HTTP/2 streams (`onInvalidMessage: TerminateStream`) and configures `X-Forwarded-For` trusted hop detection.
