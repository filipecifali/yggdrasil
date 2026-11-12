# Observability (VictoriaMetrics, Grafana, VictoriaLogs, Fluent Bit) & Autoscaling (KEDA) (`monitoring-system`, `keda-system`)

## Purpose
- **VictoriaMetrics (`monitoring-system` — *Hlidskjalf*)**: High-performance, low-memory time-series database and metric aggregation agent collecting telemetry across all cluster components.
- **Grafana (`monitoring-system` — *Hlidskjalf*)**: Interactive multi-dashboard visualization layer with provisioned VictoriaMetrics datasource, secured via Vault admin credentials and Envoy Gateway.
- **Node Exporter & Kube-State-Metrics (`monitoring-system` — *Hlidskjalf*)**: Comprehensive host hardware metrics (CPU, memory, disk, network per node) and cluster object state metrics (deployments, pods, nodes, PVCs).
- **VictoriaLogs & Fluent Bit (`monitoring-system` — *Hlidskjalf*)**: High-efficiency structured log storage with LogSQL search UI alongside a cluster-wide Fluent Bit DaemonSet streaming container logs to VictoriaLogs.
- **KEDA (`keda-system` — *Sleipnir*)**: Event-driven autoscaler scaling workloads horizontally based on VictoriaMetrics PromQL metrics and CPU thresholds.

## Manifests Location
- `infrastructure/base/victoriametrics-operator/helmrelease.yaml` — VictoriaMetrics Operator (`0.68.2`)
- `apps/base/monitoring/victoriametrics.yaml` — `VMSingle`, `VMAgent`, and `HTTPRoute` (`metrics.yggdrasil.local`)
- `apps/base/monitoring/externalsecret.yaml` — `ExternalSecret/grafana-secrets` syncing credentials from HashiCorp Vault
- `apps/base/monitoring/grafana.yaml` — `HelmRelease/grafana` (`10.5.15`) & `HTTPRoute/grafana-web` (`grafana.yggdrasil.local`)
- `apps/base/monitoring/node-exporter.yaml` — `HelmRelease/prometheus-node-exporter` (`5.1.0`) & `VMServiceScrape`
- `apps/base/monitoring/kube-state-metrics.yaml` — `HelmRelease/kube-state-metrics` (`9.0.0`) & `VMServiceScrape`
- `apps/base/monitoring/victorialogs.yaml` — `VLSingle/yggdrasil-vlsingle` (`v1.53.0`) & `HTTPRoute/victorialogs-ui` (`logs.yggdrasil.local`)
- `apps/base/monitoring/fluent-bit.yaml` — `HelmRelease/fluent-bit` (`0.58.3`) DaemonSet streaming container logs to VictoriaLogs
- `apps/base/monitoring/vmalert.yaml` — `VMAlert/yggdrasil-vmalert` alerting engine (`v1.115.0`)
- `apps/base/monitoring/alerts.yaml` — `VMRule/platform-infrastructure-alerts` active alert definitions
- `infrastructure/base/keda/helmrelease.yaml` — KEDA Operator & Metrics Server
- `apps/base/web/scaledobject.yaml` — `ScaledObject/yggdrasil-web-autoscaler`

## Key Architecture & Configurations

1. **Metrics Pipeline (VictoriaMetrics & VMAgent)**
   - `VMAgent/yggdrasil-vmagent` runs on the `platform` node pool with `selectAllByDefault: true` and `scrapeInterval: 30s`.
   - Ingests metrics from `prometheus-node-exporter` (`VMServiceScrape`), `kube-state-metrics` (`VMServiceScrape`), and internal platform services into `VMSingle/yggdrasil-vmsingle` (`30d` retention, `10Gi` storage).
   - Metrics web UI (`vmui`) exposed via Gateway API at `https://metrics.yggdrasil.local`.

2. **Visualization (Grafana)**
   - Deployed on the `apps` node pool with 5Gi persistent storage.
   - Automatically provisions VictoriaMetrics as the default Prometheus datasource (`http://vmsingle-yggdrasil-vmsingle.monitoring-system.svc.cluster.local:8429`).
   - Admin credentials synchronized automatically from HashiCorp Vault (`secret/monitoring/grafana`) through External Secrets Operator.
   - Exposed over HTTPS via Envoy Gateway `HTTPRoute` at `https://grafana.yggdrasil.local`.

3. **Node & Cluster Telemetry**
   - **Node Exporter**: DaemonSet scheduled on all 9 nodes (`hostNetwork: true`, `hostPID: true`) exporting host hardware metrics (`/proc`, `/sys`). Scraped via `VMServiceScrape`.
   - **Kube-State-Metrics**: Deployment on the `platform` pool exposing Kubernetes API resource states. Scraped via `VMServiceScrape`.

4. **Log Aggregation (VictoriaLogs & Fluent Bit)**
   - **VictoriaLogs (`VLSingle`)**: Single-instance high-density log storage engine with `14d` retention and `10Gi` persistent volume. Native web UI (`select/vmui/`) exposed at `https://logs.yggdrasil.local`.
   - **Fluent Bit**: DaemonSet across all nodes tailing container log files (`/var/log/containers/*.log`), enriching entries with Kubernetes pod/namespace/container metadata, and streaming to VictoriaLogs JSON lines endpoint (`/insert/jsonline?_stream_fields=stream,kubernetes.pod_name,kubernetes.namespace_name,kubernetes.container_name&_msg_field=log&_time_field=date`) with gzip compression.

5. **Security & Sovereign Isolation**
   - **Pod Security Admission**: `monitoring-system` namespace configured with `privileged` PSA to permit hostPath and hostNetwork access required by Node Exporter and Fluent Bit DaemonSets.
   - **Harbor Local Mirroring**: All 4 Helm charts (`grafana`, `prometheus-node-exporter`, `kube-state-metrics`, `fluent-bit`) and 5 container images are mirrored directly into the local sovereign Harbor OCI registry (`registry.yggdrasil.local/library/`).
   - **CoreDNS & DNSSEC**: Authoritative local zone records `grafana IN CNAME @` and `logs IN CNAME @` signed via DNSSEC on-the-fly.

6. **Autoscaling (KEDA)**
   - `ScaledObject/yggdrasil-web-autoscaler` dynamically scales `Deployment/yggdrasil-web` (`1` to `5` replicas) based on VictoriaMetrics PromQL queries (`sum(rate(envoy_http_downstream_rq_total[1m]))`) and CPU utilization thresholds.

7. **Alerting & Notifications (VMAlert & Zulip)**
   - When alerting is enabled, `VMAlert` executes PromQL rules (`VMRule`) against `VMSingle` and dispatches alerts to `VMAlertmanager`.
   - `VMAlertmanager` routes notifications via internal HTTP webhooks to Zulip's native Alertmanager endpoint (`https://chat.yggdrasil.local/api/v1/external/alertmanager`) into the `#alerts` stream.
   - For complete architectural details, manifest templates, and the step-by-step setup runbook, see [**Alerting Architecture: VMAlert, Alertmanager & Zulip Notifications (`vmalert-and-zulip-alerts.md`)**](vmalert-and-zulip-alerts.md).
