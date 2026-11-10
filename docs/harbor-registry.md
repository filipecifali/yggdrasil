# Harbor Container & OCI Registry (`registry-system`)

## Purpose
**Harbor** (*Sindri*) acts as the central, sovereign container image registry and Helm OCI chart registry inside the cluster at `https://registry.yggdrasil.local`. All application workloads across `apps/base/` are configured to pull their container images from Harbor's local `library` mirror (`registry.yggdrasil.local/library/*`).

## Manifests Location
- `apps/base/registry/helmrelease.yaml` — Harbor `HelmRelease` & `Secret/harbor-admin-credentials`
- `apps/base/registry/httproute.yaml` — Envoy Gateway `HTTPRoute` for `registry.yggdrasil.local`
- `infrastructure/base/helm-repositories.yaml` — Flux `HelmRepository` (`type: oci`) definitions pointing to Harbor (`oci://harbor.registry-system.svc.cluster.local/library`)
- `scripts/mirror-images-to-harbor.sh` — Configures Kind node `containerd` (`hosts.toml`) and mirrors upstream container images into Harbor
- `scripts/mirror-charts-to-harbor.sh` — Pulls all 12 upstream Helm charts and pushes them as OCI artifacts into Harbor (`library/*`)

## Mirrored Application Images (`registry.yggdrasil.local/library/*`)

| Component | Upstream Source Image | Local Harbor Mirror Image |
| :--- | :--- | :--- |
| **Envoy Proxy (`gateway`)** | `docker.io/envoyproxy/envoy:distroless-v1.33.0` | `registry.yggdrasil.local/library/envoy:distroless-v1.33.0` |
| **CoreDNS (`dns`)** | `registry.k8s.io/coredns/coredns:v1.12.0` | `registry.yggdrasil.local/library/coredns:1.12.0` |
| **HashiCorp Vault (`security`)** | `docker.io/hashicorp/vault:1.19.0` | `registry.yggdrasil.local/library/vault:1.19.0` |
| **CloudNativePG (`storage`)** | `ghcr.io/cloudnative-pg/postgresql:18.1` | `registry.yggdrasil.local/library/postgresql:18.1` |
| **SeaweedFS (`storage`)** | `docker.io/chrislusf/seaweedfs:4.53` | `registry.yggdrasil.local/library/seaweedfs:4.53` |
| **VictoriaMetrics (`monitoring`)** | `docker.io/victoriametrics/victoria-metrics:v1.115.0` | `registry.yggdrasil.local/library/victoria-metrics:v1.115.0` |
| **VMAgent (`monitoring`)** | `docker.io/victoriametrics/vmagent:v1.115.0` | `registry.yggdrasil.local/library/vmagent:v1.115.0` |
| **Forgejo (`git`)** | `code.forgejo.org/forgejo/forgejo:11.0.1-rootless` | `registry.yggdrasil.local/library/forgejo:11.0.1-rootless` |
| **Forgejo Runner (`git`)** | `code.forgejo.org/forgejo/runner:6` | `registry.yggdrasil.local/library/forgejo-runner:6` |
| **`docker-mailserver` (`mail`)** | `ghcr.io/docker-mailserver/docker-mailserver:15.0.0` | `registry.yggdrasil.local/library/docker-mailserver:15.0.0` |
| **Roundcube (`mail`)** | `docker.io/roundcube/roundcubemail:1.6.9-apache` | `registry.yggdrasil.local/library/roundcubemail:1.6.9-apache` |
| **Web Hosting (`web`)** | `docker.io/nginxinc/nginx-unprivileged:1.27-alpine` | `registry.yggdrasil.local/library/nginx-unprivileged:1.27-alpine` |
| **Kilo WireGuard Mesh (`vpn`)** | `docker.io/squat/kilo:0.7.0` | `registry.yggdrasil.local/library/kilo:0.7.0` |

## Mirrored Helm Charts (`oci://harbor.registry-system.svc.cluster.local/library/*`)

| Flux `HelmRepository` | Chart Name | Version | Upstream Source | Local Harbor OCI Artifact |
| :--- | :--- | :--- | :--- | :--- |
| `envoy-gateway` | `gateway-helm` | `1.10.0` | `oci://docker.io/envoyproxy` | `oci://harbor.registry-system.svc.cluster.local/library/gateway-helm:1.10.0` |
| `jetstack` | `cert-manager` | `v1.21.3` (`1.21.3`) | `https://charts.jetstack.io` | `oci://harbor.registry-system.svc.cluster.local/library/cert-manager:1.21.3` |
| `external-secrets` | `external-secrets` | `0.20.4` | `https://charts.external-secrets.io` | `oci://harbor.registry-system.svc.cluster.local/library/external-secrets:0.20.4` |
| `hashicorp` | `vault` | `0.34.1` | `https://helm.releases.hashicorp.com` | `oci://harbor.registry-system.svc.cluster.local/library/vault:0.34.1` |
| `cnpg` | `cloudnative-pg` | `0.29.1` | `https://cloudnative-pg.github.io/charts` | `oci://harbor.registry-system.svc.cluster.local/library/cloudnative-pg:0.29.1` |
| `victoriametrics` | `victoria-metrics-operator` | `0.68.2` | `https://victoriametrics.github.io/helm-charts/` | `oci://harbor.registry-system.svc.cluster.local/library/victoria-metrics-operator:0.68.2` |
| `kedacore` | `keda` | `2.21.0` | `https://kedacore.github.io/charts` | `oci://harbor.registry-system.svc.cluster.local/library/keda:2.21.0` |
| `forgejo` | `forgejo` | `12.5.4` | `oci://code.forgejo.org/forgejo-helm` | `oci://harbor.registry-system.svc.cluster.local/library/forgejo:12.5.4` |
| `seaweedfs` | `seaweedfs` | `4.53.0` | `https://seaweedfs.github.io/seaweedfs/helm` | `oci://harbor.registry-system.svc.cluster.local/library/seaweedfs:4.53.0` |
| `harbor` | `harbor` | `1.19.4` | `https://helm.goharbor.io` | `oci://harbor.registry-system.svc.cluster.local/library/harbor:1.19.4` |
| `coredns` | `coredns` | `1.50.4` | `https://coredns.github.io/helm` | `oci://harbor.registry-system.svc.cluster.local/library/coredns:1.50.4` |
| `docker-mailserver` | `docker-mailserver` | `4.2.4` | `https://docker-mailserver.github.io/docker-mailserver-helm` | `oci://harbor.registry-system.svc.cluster.local/library/docker-mailserver:4.2.4` |

## Important Configuration

1. **Kind `containerd` Registry Resolution (`certs.d`)**
   - `kind/cluster-config.yaml` enables `config_path = "/etc/containerd/certs.d"` on all 9 Kind nodes.
   - `scripts/mirror-images-to-harbor.sh` writes `/etc/containerd/certs.d/registry.yggdrasil.local/hosts.toml` on every Kind node pointing directly to Harbor's `ClusterIP` (`Service/harbor` in `registry-system`), allowing `containerd` on every node to pull `registry.yggdrasil.local/library/*` images without external DNS or TLS bootstrap deadlocks.

2. **Populating Harbor (`scripts/mirror-images-to-harbor.sh` & `scripts/mirror-charts-to-harbor.sh`)**
   - Once Harbor is running in `registry-system`, execute:
     ```bash
     ./scripts/mirror-images-to-harbor.sh
     ./scripts/mirror-charts-to-harbor.sh
     ```
