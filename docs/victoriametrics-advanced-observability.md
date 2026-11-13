# Yggdrasil Sovereign Observability Architecture
## VictoriaMetrics, VictoriaLogs, VictoriaTraces & Synthetic Probing

This document outlines the advanced, sovereign observability architecture deployed across the **Yggdrasil** cluster, powered by the **VictoriaMetrics** stack.

---

## 1. Observability Triad: Metrics + Logs + Traces

```
+-----------------------------------------------------------------------------------------------------------------+
|                                           YGGDRASIL SOVEREIGN APPS                                              |
|                               (Django, Celery, Forgejo, Vault, Authentik, etc.)                                 |
+-----------------------------------------------------------------------------------------------------------------+
         |                                           |                                          |
         | (1. Scraping / Pull)                      | (2. Stdout Logs)                         | (3. OpenTelemetry OTLP)
         v                                           v                                          v
+-----------------------------+             +-----------------------------+            +-------------------------+
|     VMAgent (Monitoring)    |             |    Fluent-Bit DaemonSet     |            |  VTSingle (Traces)      |
| - VMServiceScrape           |             | - Stream JSON Tailer        |            | - Port 8428             |
| - VMPodScrape               |             | - K8s Metadata Enrichment   |            | - traces.yggdrasil.local|
| - VMProbe (Synthetics)      |             |                             |            +-------------------------+
| - Stream Relabeling / Drop  |             +-----------------------------+                         |
+-----------------------------+                            |                                        |
         |                                                 | (HTTP POST /insert/jsonline)           |
         | (Remote-Write /api/v1/write)                    v                                        |
         v                                  +-----------------------------+                         |
+-----------------------------+             |      VLSingle (Logs)        |                         |
|     VMSingle (Metrics)      |             | - Port 9428                 |                         |
| - Port 8429                 |             | - logs.yggdrasil.local      |                         |
| - metrics.yggdrasil.local   |             +-----------------------------+                         |
+-----------------------------+                            |                                        |
         \                                                 |                                       /
          -------------------------------------------------+---------------------------------------
                                                           |
                                                           v
                                            +-----------------------------+
                                            |       Grafana Unified       |
                                            | - metrics: Prometheus DS    |
                                            | - logs: VictoriaLogs DS     |
                                            | - traces: Jaeger/Tempo DS   |
                                            +-----------------------------+
```

---

## 2. Implemented VictoriaMetrics Functions

### 2.1 Synthetic Outside-In Probing (`VMProbe` + `blackbox-exporter`)
* **Manifest**: `apps/base/monitoring/probes.yaml`
* **Purpose**: Performs continuous blackbox synthetic probing of HTTPRoutes, SSL validity, and critical endpoints across namespaces (`sample-app`, `storage-system`, `registry-system`, `auth-system`, `envoy-gateway-system`).
* **Labels**:
  - `app.kubernetes.io/name: platform-gateway-probes`
  - `app.kubernetes.io/component: prober`
  - `yggdrasil.io/realm: hlidskjalf`
  - `yggdrasil.io/tier: platform`

### 2.2 Worker & Ephemeral Pod Scraping (`VMPodScrape`)
* **Manifest**: `apps/base/monitoring/vmpodscrape.yaml`
* **Purpose**: Scrapes background worker pods (such as Celery workers, background queue consumers, Forgejo runners, and batch workers) directly by Pod label without needing a Kubernetes ClusterIP Service.
* **Target Selector**: `app.kubernetes.io/component in (celery-worker, background-worker, batch-worker, runner)`
* **Labels**:
  - `app.kubernetes.io/name: background-workers-podscrape`
  - `app.kubernetes.io/component: monitoring`
  - `yggdrasil.io/realm: hlidskjalf`
  - `yggdrasil.io/tier: platform`

### 2.3 Distributed Tracing Backend (`VTSingle` / VictoriaTraces)
* **Manifest**: `apps/base/monitoring/victoriatraces.yaml`
* **Purpose**: OpenTelemetry / Jaeger-compatible tracing backend storing distributed trace spans across services.
* **Ingress Route**: `traces.yggdrasil.local` protected by Authentik forward-auth via `SecurityPolicy`.
* **Labels**:
  - `app.kubernetes.io/name: victoriatraces`
  - `app.kubernetes.io/component: tracing-backend`
  - `yggdrasil.io/realm: hlidskjalf`
  - `yggdrasil.io/tier: platform`

### 2.4 Stream-Time Relabeling & Cardinality Filtering (`inlineRelabelConfig`)
* **Manifest**: `apps/base/monitoring/victoriametrics.yaml`
* **Purpose**:
  - Injects canonical cluster identification labels (`cluster: yggdrasil-sovereign`, `sovereign_tier: primary`) onto every scraped time series.
  - Automatically drops high-overhead / noisy internal runtime series (e.g. `go_memstats_gc_sys_bytes`) at the edge before committing them to persistent storage.
