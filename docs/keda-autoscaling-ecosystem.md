# KEDA Autoscaling & Serverless Ecosystem Guide

This document describes the multi-trigger event-driven autoscaling and serverless architecture implemented across the **Yggdrasil** Kubernetes platform using [KEDA](https://keda.sh/) (Kubernetes Event-driven Autoscaling) and the KEDA HTTP Add-on.

---

## Architecture Overview

KEDA acts as the sovereign cluster orchestrator for both **Deployments** (scaling between $0 \leftrightarrow N$ pods) and **ScaledJobs** (spawning on-demand batch run-to-completion Jobs):

```
                                    +------------------------------+
                                    |        Ingress / API         |
                                    |    (Envoy Gateway Bifrost)   |
                                    +--------------+---------------+
                                                   |
                                                   v
                         +---------------------------------------------------+
                         |            KEDA HTTP Interceptor Proxy            |
                         |  (Scale-to-Zero Synchronous Serverless Functions) |
                         +-------------------------+-------------------------+
                                                   |
                         +-------------------------+-------------------------+
                         |
    +--------------------+--------------------+--------------------+--------------------+
    |                                         |                                         |
    v                                         v                                         v
+-------------------------+               +-------------------------+               +-------------------------+
|     RabbitMQ Scaler     |               |    PostgreSQL Scaler    |               | VictoriaMetrics Scaler  |
|  (Asynchronous Queues)  |               |   (CNPG Batch Jobs)     |               |    (PromQL Metrics)     |
+------------+------------+               +------------+------------+               +------------+------------+
             |                                         |                                         |
             v                                         v                                         v
+-------------------------+               +-------------------------+               +-------------------------+
| Deployment/             |               | ScaledJob/              |               | Deployment/             |
| rabbitmq-worker         |               | pg-batch-worker         |               | yggdrasil-web           |
| (0 <-> 5 replicas)      |               | (0 <-> 3 batch Jobs)    |               | (1 <-> 5 replicas)      |
+-------------------------+               +-------------------------+               +-------------------------+
```

---

## 1. Synchronous Scale-to-Zero Serverless (HTTP Add-on)

* **Directory:** `apps/base/serverless/`
* **Trigger Type:** `HTTPScaledObject`
* **Target:** `Deployment/echo-fn`
* **Ingress:** `HTTPRoute` on Bifrost Envoy Gateway targeting `keda-add-ons-http-interceptor-proxy:8080` in `keda-system` with cross-namespace `ReferenceGrant`.

### Lifecycle
1. **Cold (0 replicas):** Incoming HTTP request arrives at Envoy Gateway and is routed to the interceptor proxy.
2. **Buffer & Prompt:** Interceptor buffers the connection, holds the TCP stream, and signals KEDA scaler port 9090.
3. **Warmup:** KEDA scales deployment from 0 to 1 pod. When the pod is Ready, the interceptor forwards the request and returns header `x-keda-http-cold-start: true`.
4. **Subsequent warm calls:** Routed directly through the proxy with `x-keda-http-cold-start: false` (<10ms).
5. **Idle Scaledown:** When traffic ceases for `scaledownPeriod` (30s), the deployment automatically scales back down to 0 replicas.

---

## 2. Asynchronous Queue Worker (RabbitMQ Scaler)

* **Directory:** `apps/base/serverless/rabbitmq-scaledobject.yaml`
* **Trigger Type:** `type: rabbitmq`
* **Target:** `Deployment/rabbitmq-worker` (`minReplicaCount: 0`, `maxReplicaCount: 5`)
* **Queue:** `task-queue` in virtual host `/` (`amqp://zulip:...@zulip-rabbitmq.chat-system.svc.cluster.local:5672/%2F`)

### Vault Authentication
Credentials are automatically synced from HashiCorp Vault via External Secrets Operator (`ExternalSecret/rabbitmq-keda-auth`) into a target Kubernetes Secret. `TriggerAuthentication/rabbitmq-worker-auth` binds the secret directly to KEDA without hardcoding credentials in Git:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: rabbitmq-worker-scaler
  namespace: web-system
spec:
  scaleTargetRef:
    name: rabbitmq-worker
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: rabbitmq
      metadata:
        protocol: amqp
        queueName: task-queue
        mode: QueueLength
        value: "5"
      authenticationRef:
        name: rabbitmq-worker-auth
```

---

## 3. Database Event Batch Processing (PostgreSQL ScaledJob)

* **Directory:** `apps/base/serverless/postgresql-scaledjob.yaml`
* **Trigger Type:** `type: postgresql`
* **Target:** `ScaledJob/pg-batch-worker`
* **Database Target:** CloudNative-PG cluster `yggdrasil-pg` in `storage-system` (`yggdrasil-pg-rw.storage-system.svc.cluster.local:5432`)

### How ScaledJobs Work
Instead of maintaining persistent Deployment replicas, KEDA executes ephemeral Kubernetes `Job` objects that run a container to completion and self-terminate.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: pg-batch-worker
  namespace: web-system
spec:
  jobTargetRef:
    parallelism: 1
    completions: 1
    template:
      spec:
        restartPolicy: Never
        containers:
          - name: batch-processor
            image: registry.yggdrasil.local/library/curl:8.12.1
            command: ["/bin/sh", "-c", "echo 'Processing pending records...'"]
  maxReplicaCount: 3
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 2
  triggers:
    - type: postgresql
      metadata:
        query: "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"
        targetQueryValue: "50"
      authenticationRef:
        name: pg-worker-auth
```

---

## 4. Metric-Driven Autoscaling (VictoriaMetrics / Prometheus Scaler)

* **Directory:** `apps/base/web/scaledobject.yaml`
* **Trigger Type:** `type: prometheus`
* **Target:** `Deployment/yggdrasil-web` (`minReplicaCount: 1`, `maxReplicaCount: 5`)
* **Telemetry Server:** `http://vmsingle-yggdrasil-vmsingle.monitoring-system.svc.cluster.local:8429`

KEDA queries VictoriaMetrics directly using standard PromQL expressions, avoiding any dependency on `metrics.k8s.io` (metrics-server):

```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: "http://vmsingle-yggdrasil-vmsingle.monitoring-system.svc.cluster.local:8429"
      metricName: envoy_http_downstream_rq_total
      query: sum(rate(envoy_http_downstream_rq_total[1m]))
      threshold: "50"
```

---

## 5. Scheduled Fleet Scaling (Cron Scaler Guide)

The KEDA Cron Scaler is compiled directly into the sovereign `keda-operator`. It enables time-based scaling to conserve CPU, memory, and energy outside operational hours.

### Reference Template
A turnkey reference manifest is staged in:
`apps/base/serverless/cron-scaledobject-example.yaml`

### How to Configure Schedule-Based Scaling

#### Scenario A: Scale Down Workloads Outside Business Hours
To scale non-production or tenant services down to `0` replicas on weeknights and weekends:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: tenant-cron-scaler
  namespace: web-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: target-workload
  minReplicaCount: 0  # Replicas outside the start-end window
  maxReplicaCount: 5
  cooldownPeriod: 60
  pollingInterval: 30
  triggers:
    - type: cron
      metadata:
        timezone: America/Sao_Paulo  # Target IANA timezone
        start: "0 8 * * 1-5"          # 08:00 AM Monday-Friday (Scale up)
        end: "0 18 * * 1-5"           # 06:00 PM Monday-Friday (Scale down)
        desiredReplicas: "2"
```

#### Scenario B: Nightly Maintenance / Backup Worker Pre-Warming
To scale workers up immediately before scheduled backup windows (e.g., 02:00 AM to 04:00 AM daily):

```yaml
triggers:
  - type: cron
    metadata:
      timezone: America/Sao_Paulo
      start: "0 2 * * *"
      end: "0 4 * * *"
      desiredReplicas: "4"
```

#### Key Rules for Cron Scalers:
1. **Timezone:** Always specify standard IANA timezone format (e.g., `America/Sao_Paulo`, `Etc/UTC`, `Europe/London`).
2. **Cron Format:** Standard 5-field cron syntax (`Minute Hour DayOfMonth Month DayOfWeek`).
3. **Multiple Triggers:** When combining Cron with Prometheus or HTTP triggers in one `ScaledObject`, KEDA calculates the replica count for each trigger and selects the **highest** value (`max`).
4. **Never run concurrent HPAs:** Ensure no standalone Kubernetes `HorizontalPodAutoscaler` is targeting the same Deployment, as KEDA generates and manages its own internal HPA (`keda-hpa-<scaledobject-name>`).

---

## 6. Verification and Status

| Workload | Namespace | Trigger | Scaling Range | Status |
| :--- | :--- | :--- | :--- | :--- |
| `echo-fn` | `web-system` | HTTP Add-on | $0 \leftrightarrow 5$ | **Active** (Verified Cold/Warm/Idle) |
| `rabbitmq-worker` | `web-system` | RabbitMQ Queue | $0 \leftrightarrow 5$ | **Active** (`READY: True`) |
| `pg-batch-worker` | `web-system` | PostgreSQL Query | $0 \leftrightarrow 3$ Jobs | **Active** (`READY: True`) |
| `yggdrasil-web` | `web-system` | VictoriaMetrics PromQL | $1 \leftrightarrow 5$ | **Active** (`0/50` avg rq/s) |
| `cron-template` | `web-system` | Cron / Schedule | $0 \leftrightarrow 5$ | **Documented Template** |
