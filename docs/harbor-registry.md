# Harbor Container & OCI Registry (`registry-system`)

## Purpose
**Harbor** (*Sindri*) acts as the central, sovereign container image registry and Helm OCI chart registry inside the cluster at `https://registry.yggdrasil.local`. All application workloads across `apps/base/` are configured to pull their container images from Harbor's local `library` mirror (`registry.yggdrasil.local/library/*`).

## Manifests Location
- `apps/base/registry/helmrelease.yaml` — Harbor `HelmRelease` & `Secret/harbor-admin-credentials`
- `apps/base/registry/httproute.yaml` — Envoy Gateway `HTTPRoute` for `registry.yggdrasil.local`
- `scripts/mirror-images-to-harbor.sh` — Configures Kind node `containerd` (`hosts.toml`) and mirrors upstream images into Harbor

## Mirrored Application Images (`registry.yggdrasil.local/library/*`)

| Component | Upstream Source Image | Local Harbor Mirror Image |
| :--- | :--- | :--- |
| **Envoy Proxy (`gateway`)** | `docker.io/envoyproxy/envoy:distroless-v1.33.0` | `registry.yggdrasil.local/library/envoy:distroless-v1.33.0` |
| **CoreDNS (`dns`)** | `registry.k8s.io/coredns/coredns:v1.12.0` | `registry.yggdrasil.local/library/coredns:1.12.0` |
| **HashiCorp Vault (`security`)** | `docker.io/hashicorp/vault:1.19.0` | `registry.yggdrasil.local/library/vault:1.19.0` |
| **CloudNativePG (`storage`)** | `ghcr.io/cloudnative-pg/postgresql:18.1` | `registry.yggdrasil.local/library/postgresql:18.1` |
| **SeaweedFS (`storage`)** | `docker.io/chrislusf/seaweedfs:4.00` | `registry.yggdrasil.local/library/seaweedfs:4.00` |
| **VictoriaMetrics (`monitoring`)** | `docker.io/victoriametrics/victoria-metrics:v1.115.0` | `registry.yggdrasil.local/library/victoria-metrics:v1.115.0` |
| **VMAgent (`monitoring`)** | `docker.io/victoriametrics/vmagent:v1.115.0` | `registry.yggdrasil.local/library/vmagent:v1.115.0` |
| **Forgejo (`git`)** | `code.forgejo.org/forgejo/forgejo:11.0.1` | `registry.yggdrasil.local/library/forgejo:11.0.1` |
| **Forgejo Runner (`git`)** | `code.forgejo.org/forgejo/runner:6` | `registry.yggdrasil.local/library/forgejo-runner:6` |
| **`docker-mailserver` (`mail`)** | `ghcr.io/docker-mailserver/docker-mailserver:15.0.0` | `registry.yggdrasil.local/library/docker-mailserver:15.0.0` |
| **Roundcube (`mail`)** | `docker.io/roundcube/roundcubemail:1.6.9-apache` | `registry.yggdrasil.local/library/roundcubemail:1.6.9-apache` |
| **Web Hosting (`web`)** | `docker.io/nginxinc/nginx-unprivileged:1.27-alpine` | `registry.yggdrasil.local/library/nginx-unprivileged:1.27-alpine` |

## Important Configuration

1. **Kind `containerd` Registry Resolution (`certs.d`)**
   - `kind/cluster-config.yaml` enables `config_path = "/etc/containerd/certs.d"` on all 9 Kind nodes.
   - `scripts/mirror-images-to-harbor.sh` writes `/etc/containerd/certs.d/registry.yggdrasil.local/hosts.toml` on every Kind node pointing directly to Harbor's `ClusterIP` (`Service/harbor` in `registry-system`), allowing `containerd` on every node to pull `registry.yggdrasil.local/library/*` images without external DNS or TLS bootstrap deadlocks.

2. **Populating Harbor (`scripts/mirror-images-to-harbor.sh`)**
   - Once Harbor is running in `registry-system`, execute:
     ```bash
     ./scripts/mirror-images-to-harbor.sh
     ```
