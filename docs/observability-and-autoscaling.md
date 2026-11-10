# Observability (VictoriaMetrics) & Autoscaling (KEDA) (`monitoring-system`, `keda-system`)

## Purpose
- **VictoriaMetrics (`monitoring-system` — *Hlidskjalf*)**: Collects, stores, and queries time-series metrics from all cluster operators and workloads while using a fraction of the RAM of standard Prometheus.
- **KEDA (`keda-system` — *Sleipnir*)**: Scales Kubernetes workloads horizontally based on event-driven triggers and VictoriaMetrics PromQL queries.

## Manifests Location
- `infrastructure/base/victoriametrics-operator/helmrelease.yaml` — VictoriaMetrics Operator
- `apps/base/monitoring/victoriametrics.yaml` — `VMSingle`, `VMAgent`, and `HTTPRoute` (`metrics.yggdrasil.local`)
- `infrastructure/base/keda/helmrelease.yaml` — KEDA Operator & Metrics Server
- `apps/base/web/scaledobject.yaml` — `ScaledObject/yggdrasil-web-autoscaler`

## Important Configuration

1. **Automatic Prometheus Discovery (`disable_prometheus_converter: false`)**
   - VictoriaMetrics Operator automatically converts standard Prometheus `ServiceMonitor` and `PodMonitor` objects (such as those created by CloudNativePG, KEDA, and CoreDNS) into `VMServiceScrape`/`VMPodScrape` resources.
   - `VMAgent/yggdrasil-vmagent` uses `selectAllByDefault: true` (`scrapeInterval: 30s`) and remote-writes into `VMSingle/yggdrasil-vmsingle` (`30d` retention, `10Gi` PVC).
   - The `vmui` query dashboard is exposed via Envoy Gateway at `https://metrics.yggdrasil.local`.

2. **VictoriaMetrics-Driven KEDA Autoscaling (`scaledobject.yaml`)**
   - `ScaledObject/yggdrasil-web-autoscaler` scales `Deployment/yggdrasil-web` (`1` to `5` replicas across the 3 `apps` worker nodes) by querying `http://vmsingle-yggdrasil-vmsingle.monitoring-system.svc.cluster.local:8429` for `sum(rate(envoy_http_downstream_rq_total[1m]))` alongside a `75%` CPU utilization trigger.
