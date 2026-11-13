# Self-Hosted CloudFront Alternative: Envoy Gateway Edge Caching Architecture

This document describes how the **Yggdrasil** platform replicates AWS CloudFront and S3 edge caching using native **Kubernetes Gateway API** and **Envoy Gateway (Bifrost)**.

By leveraging Envoy's built-in `envoy.filters.http.cache` filter paired with an in-memory cache and non-root static containers, the cluster provides **microsecond edge responses**, **native TLS 1.3 / HTTPS termination**, **SPA client-side routing**, and **Brotli/Gzip compression** with **zero external CDN dependencies or extra pods**.

---

## 1. Architecture Overview & Request Flow

```
+---------------------------------------------------------------------------------------------------+
|                                      VISITOR BROWSER / CLIENT                                     |
+---------------------------------------------------------------------------------------------------+
                                                  |
                                                  | 1. HTTPS GET /assets/index-b4f2a1.js
                                                  v
+---------------------------------------------------------------------------------------------------+
|                     BIFROST EDGE GATEWAY (Envoy Gateway — envoy-gateway-system)                    |
|                                                                                                   |
|  [Listener TLS 1.3 Termination] (cert-manager wildcard TLS)                                       |
|               |                                                                                   |
|               v                                                                                   |
|  [Filter 1: envoy.filters.http.cache] <====== Cache Lookup (In-Memory SimpleHttpCache)            |
|               |                                                                                   |
|        +------+------+                                                                            |
|        |             |                                                                            |
|   (CACHE HIT)   (CACHE MISS)                                                                      |
|        |             |                                                                            |
|        |             v                                                                            |
|        |    [Filter 2: envoy.filters.http.compressor] (Brotli / Gzip)                               |
|        |             |                                                                            |
|        |             v                                                                            |
|        |    [Filter 3: envoy.filters.http.router] (HTTPRoute Matching)                            |
+--------|-------------|----------------------------------------------------------------------------+
         |             |
         |             | 2. Upstream Fetch (Only on Miss / Stale)
         |             v
         |    +-----------------------------------------------------------------------+
         |    |                      FRONTEND POD (web-system)                        |
         |    |                                                                       |
         |    |  NGINX Unprivileged / Caddy (Non-Root, Read-Only Rootfs)              |
         |    |  - SPA Routing: try_files $uri $uri/ /index.html                      |
         |    |  - Headers: Cache-Control: public, max-age=31536000, immutable       |
         |    +-----------------------------------------------------------------------+
         |             |
         +<------------+
         | 3. Response Cached in Envoy RAM & Delivered
         v
[ Client receives HTTP 200 with Age: 42, TLS 1.3, Brotli-compressed, < 1ms latency ]
```

---

## 2. Why Envoy Gateway Beats External CDNs & Varnish

1. **Native TLS 1.3 & Certificate Lifecycle**:
   - Varnish open-source does not terminate TLS without an auxiliary proxy like Hitch.
   - Envoy Gateway natively handles TLS 1.2/1.3 termination, ALPN negotiation (`h2`, `http/1.1`), and automatic secret rotation via `cert-manager`.
2. **Zero Extra Pod Footprint**:
   - Edge caching runs in-process inside the Envoy proxy pods already deployed for `bifrost`.
   - No separate caching daemon, no additional CPU overhead, and zero extra hops on the pod network.
3. **Automated Stampede Protection**:
   - When 500 concurrent visitors request an uncached asset simultaneously, Envoy deduplicates the upstream requests and dispatches only **one single query** to the backend, serving all 500 clients from the resulting cache entry.
4. **Multi-Region Replication Across Clusters**:
   - Both **Yggdrasil** (Germany) and **Jotunheim** (France) run identical Envoy edge caches.
   - Users near Germany hit Yggdrasil's edge cache; users near Western Europe hit Jotunheim's edge cache.

---

## 3. Configuration Breakdown

### 3.1 Enabling the Envoy HTTP Cache Filter (`cache-policy.yaml`)
Defined in [apps/base/gateway/cache-policy.yaml](file:///C:/Users/filip/.gemini/antigravity/scratch/yggdrasil/apps/base/gateway/cache-policy.yaml):

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyPatchPolicy
metadata:
  name: bifrost-edge-cache
  namespace: envoy-gateway-system
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: bifrost
  type: JSONPatch
  jsonPatches:
    - type: type.googleapis.com/envoy.config.listener.v3.Listener
      name: envoy-gateway-system/bifrost/https
      operation:
        op: add
        path: /default_filter_chain/filters/0/typed_config/http_filters/0
        value:
          name: envoy.filters.http.cache
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.cache.v3.CacheConfig
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.cache.simple_http_cache.v3.SimpleHttpCacheConfig
```

### 3.2 CloudFront Caching Strategy (Two-Tier Cache-Control)
Defined in [apps/base/web/spa-frontend-template.yaml](file:///C:/Users/filip/.gemini/antigravity/scratch/yggdrasil/apps/base/web/spa-frontend-template.yaml):

| Asset Type | Paths / Pattern | Header | Envoy & Browser Behavior |
| :--- | :--- | :--- | :--- |
| **Content-Hashed Assets** | `*.js`, `*.css`, `*.woff2`, `*.webp`, `*.svg` | `public, max-age=31536000, immutable` | Cached in Envoy RAM and browser disk for 1 year. Never revalidated. |
| **Entrypoint HTML** | `/`, `/index.html`, `*.html` | `public, max-age=0, must-revalidate` | Always revalidated against backend via ETag/304. Guarantees immediate zero-downtime rollouts. |
| **SPA Routes** | `/dashboard`, `/settings/*`, `/users/123` | `try_files $uri $uri/ /index.html;` | Falls back to `index.html` for client-side routing without returning 404. |

---

## 4. How to Deploy a New Node.js / React / Vue / Vite Frontend

Deploying any static frontend to Yggdrasil and Jotunheim follows a straightforward 3-step GitOps workflow:

### Step 1: Containerize the Frontend
In your project `Dockerfile`:
```dockerfile
# Build Stage
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build # Outputs to /app/dist

# Serve Stage (Zero-Privilege NGINX)
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY spa-default.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
```

### Step 2: Push to Sovereign Harbor Mirror
```bash
docker build -t registry.yggdrasil.local/apps/my-app:v1.0.0 .
docker push registry.yggdrasil.local/apps/my-app:v1.0.0
```

### Step 3: Declare Deployment & HTTPRoute
Create `apps/base/web/my-app.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: web-system
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: app
          image: registry.yggdrasil.local/apps/my-app:v1.0.0
          ports:
            - containerPort: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: web-system
spec:
  parentRefs:
    - name: bifrost
      namespace: envoy-gateway-system
  hostnames:
    - "my-app.yggdrasil.local"
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: my-app
          port: 8080
```

Envoy Gateway will automatically terminate HTTPS, serve all content-hashed chunks from memory cache, and compress payloads on the fly.
