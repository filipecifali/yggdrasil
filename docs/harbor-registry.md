# Harbor Container & OCI Registry (`registry-system`)

## Purpose
**Harbor** (*Sindri*) acts as the central, sovereign container image registry and Helm OCI chart registry inside the cluster at `https://registry.yggdrasil.local`. All application workloads across `apps/base/` are configured to pull their container images from Harbor's local `library` mirror (`registry.yggdrasil.local/library/*`).

The `library` project is hardened with **private access** (`public: false`) and user self-registration disabled. Containerd on all Kind nodes is pre-authenticated with internal registry credentials to permit unprivileged CRI image pulls without requiring per-pod `imagePullSecrets`.

## Manifests Location
- `apps/base/registry/helmrelease.yaml` — Harbor `HelmRelease` & `Secret/harbor-admin-credentials`
- `apps/base/registry/httproute.yaml` — Envoy Gateway `HTTPRoute` for `registry.yggdrasil.local`
- `infrastructure/base/helm-repositories.yaml` — Flux `HelmRepository` (`type: oci`) definitions pointing to Harbor (`oci://harbor.registry-system.svc.cluster.local/library`)
- `scripts/configure-harbor-private.sh` — Hardens Harbor project to private, disables public self-registration, and configures node containerd credentials
- `scripts/mirror-images-to-harbor.sh` — Configures Kind node `containerd` (`hosts.toml` & `config.toml`) and mirrors upstream container images into Harbor
- `scripts/mirror-charts-to-harbor.sh` — Pulls all 18 upstream Helm charts and pushes them as OCI artifacts into Harbor (`library/*`)

## Mirrored Application Images (`registry.yggdrasil.local/library/*`)

| Component | Upstream Source Image | Local Harbor Mirror Image |
| :--- | :--- | :--- |
| **Envoy Proxy (`gateway`)** | `docker.io/envoyproxy/envoy:distroless-v1.33.0` | `registry.yggdrasil.local/library/envoy:distroless-v1.40.2` |
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
| **Authentik Server (`auth`)** | `ghcr.io/goauthentik/server:2026.8.5` | `registry.yggdrasil.local/library/authentik-server:2026.8.5` |
| **Authentik LDAP Outpost (`auth`)** | `ghcr.io/goauthentik/ldap:2026.8.5` | `registry.yggdrasil.local/library/authentik-ldap:2026.8.5` |
| **Zulip Server (`chat`)** | `ghcr.io/zulip/zulip-server:12.4-0` | `registry.yggdrasil.local/library/zulip-server:12.4-0` |
| **Zulip PostgreSQL (`chat`)** | `docker.io/zulip/zulip-postgresql:14` | `registry.yggdrasil.local/library/zulip-postgresql:14` |
| **RabbitMQ (`chat`)** | `docker.io/bitnamilegacy/rabbitmq:4.1.3` | `registry.yggdrasil.local/library/rabbitmq:4.1.3` |
| **Memcached (`chat`)** | `docker.io/bitnamilegacy/memcached:latest` | `registry.yggdrasil.local/library/memcached:latest` |
| **Redis (`chat`)** | `docker.io/bitnamilegacy/redis:latest` | `registry.yggdrasil.local/library/redis:latest` |
| **Grafana (`monitoring`)** | `docker.io/grafana/grafana:12.3.1` | `registry.yggdrasil.local/library/grafana:12.3.1` |
| **Node Exporter (`monitoring`)** | `quay.io/prometheus/node-exporter:v1.12.1` | `registry.yggdrasil.local/library/node-exporter:v1.12.1` |
| **Kube-State-Metrics (`monitoring`)** | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0` | `registry.yggdrasil.local/library/kube-state-metrics:v2.20.0` |
| **VictoriaLogs (`monitoring`)** | `docker.io/victoriametrics/victoria-logs:v1.53.0` | `registry.yggdrasil.local/library/victoria-logs:v1.53.0` |
| **Fluent Bit (`monitoring`)** | `cr.fluentbit.io/fluent/fluent-bit:5.1.3` | `registry.yggdrasil.local/library/fluent-bit:5.1.3` |

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
| `authentik` | `authentik` | `2026.8.5` | `https://charts.goauthentik.io` | `oci://harbor.registry-system.svc.cluster.local/library/authentik:2026.8.5` |
| `zulip` | `zulip` | `2.4.0` | `oci://ghcr.io/zulip/helm-charts` | `oci://harbor.registry-system.svc.cluster.local/library/zulip:2.4.0` |
| `grafana` | `grafana` | `10.5.15` | `https://grafana.github.io/helm-charts` | `oci://harbor.registry-system.svc.cluster.local/library/grafana:10.5.15` |
| `prometheus-community` | `prometheus-node-exporter` | `5.1.0` | `https://prometheus-community.github.io/helm-charts` | `oci://harbor.registry-system.svc.cluster.local/library/prometheus-node-exporter:5.1.0` |
| `prometheus-community` | `kube-state-metrics` | `9.0.0` | `https://prometheus-community.github.io/helm-charts` | `oci://harbor.registry-system.svc.cluster.local/library/kube-state-metrics:9.0.0` |
| `fluent` | `fluent-bit` | `0.58.3` | `https://fluent.github.io/helm-charts` | `oci://harbor.registry-system.svc.cluster.local/library/fluent-bit:0.58.3` |

## Important Configuration

1. **Kind `containerd` Registry Resolution & Authentication**
   - `kind/cluster-config.yaml` enables `config_path = "/etc/containerd/certs.d"` on all 9 Kind nodes.
   - `scripts/configure-harbor-private.sh` and `scripts/mirror-images-to-harbor.sh` configure `/etc/containerd/certs.d/registry.yggdrasil.local/hosts.toml` and `/etc/containerd/config.toml` on every Kind node with internal Harbor credentials, allowing containerd to pull `registry.yggdrasil.local/library/*` images securely while blocking unauthenticated external pulls.

2. **Populating Harbor (`scripts/mirror-images-to-harbor.sh` & `scripts/mirror-charts-to-harbor.sh`)**
   - Once Harbor is running in `registry-system`, execute:
     ```bash
     ./scripts/configure-harbor-private.sh
     ./scripts/mirror-images-to-harbor.sh
     ./scripts/mirror-charts-to-harbor.sh
     ```

---

## Cross-Cluster Harbor Replication (`jotunheim`)

Harbor supports automated, sovereign multi-cluster image and OCI artifact synchronization. A secondary Harbor registry is deployed in the **Jotunheim** secondary cluster (`registry-system` namespace) and paired with Yggdrasil via an event-based replication rule.

```
+-------------------------------------------------------------+
|                  Cluster: Yggdrasil (Primary)               |
|                    registry.yggdrasil.local                 |
|                                                             |
|   +-----------------------------------------------------+   |
|   | Harbor Core & Jobservice Engine                     |   |
|   | - Project: library (Private)                        |   |
|   | - Policy: replicate-to-jotunheim                    |   |
|   | - Trigger: Event-Based (on image push) & Manual     |   |
|   +--------------------------+--------------------------+   |
+------------------------------|------------------------------+
                               |
                               v (Kilo WireGuard Mesh / NodePort 30080)
+-------------------------------------------------------------+
|                  Cluster: Jotunheim (Secondary)             |
|                    registry.jotunheim.local                 |
|                                                             |
|   +-----------------------------------------------------+   |
|   | Harbor Core & Local Registry                        |   |
|   | - Project: library                                  |   |
|   | - Storage: local-path 5Gi PVC                       |   |
|   +-----------------------------------------------------+   |
+-------------------------------------------------------------+
```

### Replication Architecture
1. **Endpoint Target**: Yggdrasil Harbor registers Jotunheim Harbor (`http://172.18.0.9:30080` or `http://registry.jotunheim.local`) as an authenticated remote registry endpoint using basic authentication.
2. **Replication Policy (`replicate-to-jotunheim`)**:
   - **Mode**: Push-based replication from Yggdrasil (`library/**`) to Jotunheim (`library`).
   - **Trigger**: `event_based` (replicates automatically and immediately whenever any container image or Helm OCI chart is pushed to Yggdrasil).
   - **Deletion & Override**: Enabled to ensure synchronization parity.
3. **Automated Setup & Verification**:
   - Setup Script: `scripts/setup-harbor-replication.py`
   - Verification Script: `scripts/verify-harbor-replication.py`
   - Test Validation: Verified through `scripts/test-cluster-configs.sh` (Test 11).

