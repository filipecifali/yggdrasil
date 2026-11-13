# Sample App: Full-Stack Django Diagnostic Hub

A sovereign, cloud-native sample **Django 5.1** application with **Celery 5.4**, designed to demonstrate and validate integration across four core platform services:

1. **PostgreSQL**: Relational persistence and migration management.
2. **Redis**: High-speed in-memory caching and Celery task result backend.
3. **RabbitMQ**: AMQP message broker for asynchronous job queueing.
4. **SeaweedFS S3**: S3-compatible object storage via `boto3` and `django-storages`.

All components are fully containerized, non-root hardened (UID 10001), packaged into a self-contained **Helm chart** following **Semantic Versioning (1.1.0)**, and designed for isolated ephemeral environments with native **VictoriaMetrics APM & Metrics** and **VictoriaLogs Structured Logging**.

---

## 1. Architecture & Component Interaction

```
+---------------------------------------------------------------------------------------------------+
|                                      VISITOR / CLIENT BROWSER                                     |
+---------------------------------------------------------------------------------------------------+
                                                  |
                                    HTTPS (sample.yggdrasil.local)
                                                  v
+---------------------------------------------------------------------------------------------------+
|                            BIFROST GATEWAY (Envoy Gateway — Bifrost)                              |
|                          HTTPRoute: sample.yggdrasil.local -> Port 8000                           |
+---------------------------------------------------------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
|                             NAMESPACE: sample-app (ISOLATED REALM)                                |
|                                                                                                   |
|  +-----------------------------+        (1. AMQP Dispatch)        +----------------------------+  |
|  |    Django Web (Gunicorn)    |--------------------------------->|      RabbitMQ Broker       |  |
|  | - Port 8000                 |                                  | - Port 5672 (AMQP)         |  |
|  | - UI & Diagnostic APIs      |                                  | - Exchange & Task Queue    |  |
|  +-----------------------------+                                  +----------------------------+  |
|          |             |                                                        |                 |
|          | (2. Read/   | (3. Cache/Session)                                     | (Task Pick-up)  |
|          |     Write)  v                                                        v                 |
|          |     +---------------+         (4. Results / Status)    +----------------------------+  |
|          |     |  Redis Cache  |<---------------------------------|   Celery Async Worker      |  |
|          |     | - Port 6379   |                                  | - Background Executions    |  |
|          |     +---------------+                                  | - Health Verification      |  |
|          v                                                        +----------------------------+  |
|  +-----------------------------+                                                |                 |
|  |     PostgreSQL DB           |                                                |                 |
|  | - Port 5432                 |                                                |                 |
|  | - Schemas & Run History     |                                                |                 |
|  +-----------------------------+                                                |                 |
+---------------------------------------------------------------------------------|-----------------+
                                                                                  |
                                                                                  | (5. S3 Payload)
                                                                                  v
+---------------------------------------------------------------------------------------------------+
|                         STORAGE-SYSTEM: SeaweedFS S3 Object Storage                               |
|                         Endpoint: http://seaweedfs-s3.storage-system:8333                         |
|                         Bucket: sample-app-demo                                                   |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. Directory Structure

```
sample-app/
├── VERSION                     # SemVer: 1.0.0
├── requirements.txt            # Django, Celery, Redis, Psycopg3, Boto3, Gunicorn
├── Dockerfile                  # Multi-stage non-root container (UID 10001)
├── manage.py                   # Django CLI management
├── config/
│   ├── settings.py             # Database, Cache, Celery, and S3 settings
│   ├── celery.py               # Celery app instantiation
│   ├── urls.py                 # URL routing
│   └── wsgi.py                 # WSGI entrypoint
├── dashboard/
│   ├── models.py               # DiagnosticRun, ServiceCheck, S3DiagnosticFile
│   ├── tasks.py                # Celery async diagnostic task
│   ├── views.py                # Dashboard & REST APIs
│   ├── urls.py                 # Dashboard routes
│   └── templates/
│       └── dashboard/
│           └── index.html      # Responsive Dark-Mode Diagnostics Dashboard
└── chart/                      # Self-Contained Helm Chart (Version: 1.0.0)
    ├── Chart.yaml              # Chart metadata & SemVer
    ├── values.yaml             # Configurable values & toggles
    └── templates/
        ├── configmap.yaml
        ├── secret.yaml
        ├── django-deployment.yaml
        ├── django-service.yaml
        ├── celery-deployment.yaml
        ├── in-namespace-postgres.yaml
        ├── in-namespace-redis.yaml
        ├── in-namespace-rabbitmq.yaml
        ├── httproute.yaml
        ├── networkpolicy.yaml
        └── vmservicescrape.yaml
```

---

## 3. Helm Chart Usage & Ephemeral Environments

The chart is designed so that every dependency is isolated within the release namespace, making it turnkey for **ephemeral preview environments** (e.g., Pull Request demo environments).

### 3.1 Deploying as an Ephemeral Environment
```bash
# Deploy a dedicated preview environment for PR #42 in its own isolated namespace
helm install pr-42 ./chart \
  --namespace pr-42 \
  --create-namespace \
  --set gateway.hostname="pr-42.yggdrasil.local"
```

### 3.2 Helm Chart Values Overview (`values.yaml`)
* `django.replicaCount`: Number of web application pods (default: 1).
* `celery.concurrency`: Celery worker concurrency level (default: 2).
* `inNamespaceDependencies.postgres.enabled`: Spawns a dedicated in-namespace PostgreSQL instance (default: `true`).
* `inNamespaceDependencies.redis.enabled`: Spawns a dedicated in-namespace Redis instance (default: `true`).
* `inNamespaceDependencies.rabbitmq.enabled`: Spawns a dedicated in-namespace RabbitMQ broker (default: `true`).
* `seaweedfs.endpointUrl`: S3 endpoint URL (default: `http://seaweedfs-s3.storage-system.svc.cluster.local:8333`).
* `gateway.hostname`: Domain routed via Bifrost Envoy Gateway (default: `sample.yggdrasil.local`).

---

## 4. API & Health Endpoints

| Endpoint | Method | Description |
| :--- | :--- | :--- |
| `/` | `GET` | Interactive Diagnostic Web Dashboard |
| `/api/diagnostics/run` | `POST` | Dispatches an async full-stack diagnostic run via RabbitMQ |
| `/api/diagnostics/<uuid>` | `GET` | Returns status, latencies, and S3 artifact metadata for a specific run |
| `/api/metrics` | `GET` | Summary metrics (total runs, pass/fail counts, success rate) |
| `/healthz` | `GET` | Kubernetes Liveness Probe |
| `/readyz` | `GET` | Kubernetes Readiness Probe (validates database connection) |
| `/metrics` | `GET` | Prometheus / VictoriaMetrics scrape endpoint (Django, DB, cache & custom APM metrics) |

---

## 5. Observability: VictoriaMetrics APM & VictoriaLogs

The application is natively pre-configured for sovereign observability:

1. **VictoriaMetrics (`VMServiceScrape`)**:
   - `VMAgent` in `monitoring-system` discovers and scrapes `/metrics` every 15s.
   - Database connection pools, query latencies, cache hit/miss rates, and HTTP request metrics are exposed via `django-prometheus`.
   - Custom APM instrumentation:
     - `sample_app_diagnostic_runs_total{trigger_type="api"}`: Total diagnostic tasks dispatched.
     - `sample_app_diagnostic_run_duration_seconds`: Histogram of full-stack execution latencies.
     - `sample_app_service_health_status{service="postgres|redis|rabbitmq|seaweedfs"}`: Live dependency health gauges (1 = pass, 0 = fail).
     - `sample_app_service_latency_ms{service="..."}`: Granular round-trip latency per dependency.

2. **VictoriaLogs (JSON Log Streaming)**:
   - Formatted using `python-json-logger` emitting ISO8601 timestamps, log levels, logger namespaces, module names, and custom attributes (`run_id`, `duration_ms`, `event`).
   - Fluent-Bit daemonset automatically tails standard output and streams structured JSON lines into `vlsingle-yggdrasil-vlsingle:9428`.

3. **Network Isolation Hardening**:
   - `NetworkPolicy` allows incoming TCP port 8000 scraping exclusively from `monitoring-system` alongside `envoy-gateway-system`.
