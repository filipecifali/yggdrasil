# Web Hosting & MTA-STS Policy Server (`web-system`)

## Purpose
Hosts web content (`yggdrasil.local`, `www.yggdrasil.local`) and serves the **RFC 8461 MTA-STS policy file** (`https://mta-sts.yggdrasil.local/.well-known/mta-sts.txt`) inside the `restricted` Pod Security Standard namespace `web-system` (*Midgard*).

## Manifests Location
- `apps/base/web/web-hosting.yaml` — `ConfigMap`, unprivileged NGINX `Deployment`, `Service`, and `HTTPRoute`
- `apps/base/web/scaledobject.yaml` — KEDA `ScaledObject`

## Important Configuration

1. **Pod Security `restricted` Compliance**
   - Runs `nginxinc/nginx-unprivileged:1.27-alpine` on port `8080` as non-root `UID 101`.
   - Enforces `readOnlyRootFilesystem: true` (mounting `emptyDir` volumes at `/tmp`, `/var/cache/nginx`, and `/var/run`), `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, and `automountServiceAccountToken: false`.

2. **Edge Caching & Security Headers (`HTTPRoute/yggdrasil-web`)**
   - Injects `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`, `Cache-Control: public, max-age=300, stale-while-revalidate=60`, `Content-Security-Policy`, `X-Content-Type-Options: nosniff`, and `X-Frame-Options: DENY` at the Envoy Gateway layer.
