# Cross-Cluster Replication & Disaster Recovery Guide

This document defines the architecture, configuration, and disaster recovery procedures for **end-to-end multi-cluster replication** between **Yggdrasil** (Primary Cluster — Hetzner, Falkenstein/Nuremberg, Germany) and **Jotunheim** (Secondary / Standby Cluster — OVHcloud, Gravelines/Strasbourg, France).

Both clusters are interconnected over a sovereign, kernel-native **Kilo WireGuard encrypted mesh tunnel**, establishing direct, authenticated Pod-to-Pod and Node-to-Node routing across providers without traversing public transit unencrypted.

---

## 1. Multi-Cluster Architecture & Subsystem Replication Matrix

```
+-------------------------------------------------------------------------------------------------------------------+
|                                            KILO WIREGUARD ENCRYPTED MESH                                          |
|                                                                                                                   |
|   +------------------------------------+                                   +----------------------------------+   |
|   |      YGGDRASIL (Hetzner, DE)       |                                   |     JOTUNHEIM (OVHcloud, FR)     |   |
|   |           [PRIMARY]                |                                   |        [STANDBY / REPLICA]      |   |
|   |                                    |                                   |                                  |   |
|   | 1. CloudNativePG (Read-Write)      |======== Streaming WAL / TLS =====>| 1. CloudNativePG (Standby Repl.) |   |
|   | 2. SeaweedFS S3 Master             |<======= Continuous S3 Sync ======>| 2. SeaweedFS S3 Secondary        |   |
|   | 3. Harbor OCI Mirror               |<======= Two-Way Replication =====>| 3. Harbor OCI Standby Mirror     |   |
|   | 4. VictoriaMetrics Agent           |======== Dual Remote-Write =======>| 4. Global VictoriaMetrics TSDB   |   |
|   | 5. Docker Mailserver (MX 10)       |======== Dovecot dsync Sync ======>| 5. Docker Mailserver (MX 20)     |   |
|   | 6. RabbitMQ Broker                 |<======= Federation Upstream =====>| 6. RabbitMQ Standby Broker       |   |
|   | 7. CoreDNS Authoritative (Master)  |======== AXFR Zone Transfer ======>| 7. CoreDNS Secondary (Slave)     |   |
|   | 8. Authentik OIDC Provider         |======== Cross-Cluster IdP =======>| 8. Kubernetes API OIDC Auth      |   |
|   +------------------------------------+                                   +----------------------------------+   |
+-------------------------------------------------------------------------------------------------------------------+
```

### Subsystem Recovery Objectives (RTO / RPO)

| Subsystem | Primary Component | Replication Protocol | Topology | RPO (Data Loss) | RTO (Recovery Time) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Relational Database** | CloudNativePG (`yggdrasil-pg`, `authentik-pg`) | PostgreSQL Streaming WAL & Barman S3 | Active / Standby | `< 1 second` | `< 30 seconds` (`kubectl cnpg promote`) |
| **Object Storage** | SeaweedFS (`storage-system`) | Filer S3 Active-Active Sync | Active / Active | `< 15 minutes` | `0 seconds` (Instant local read/write) |
| **Container Registry** | Harbor (`registry-system`) | Harbor Two-Way Push/Pull | Active / Active | `< 5 minutes` | `0 seconds` (Identical OCI digest cache) |
| **Metrics & Logs** | VictoriaMetrics & VictoriaLogs | Dual-Write `remoteWrite` & Fluent Bit | Active / Active | `0 seconds` | `0 seconds` (Telemetry survives in peer) |
| **Email Mailboxes** | Docker-Mailserver & Dovecot | Dovecot `dsync` over TLS | Active (MX 10) / Standby (MX 20) | `< 5 seconds` | `< 10 seconds` (Automated MX failover) |
| **Message Broker** | RabbitMQ (`chat-system`) | RabbitMQ Federation & Shovels | Active / Federated | Near Real-Time | `< 1 minute` |
| **DNS Resolution** | CoreDNS (`dns-system`) | RFC 5936 AXFR / NOTIFY | Primary / Secondary | Near Real-Time | `0 seconds` (Local resolver fallback) |
| **Identity & Access** | Authentik (`auth-system`) | OIDC Discovery & CA trust | Central Primary / Remote Client | Near Real-Time | `< 1 minute` |

---

## 2. Replication Mechanism Specifications

### 2.1 CloudNativePG Standby Replica Clusters
The secondary cluster runs identical CloudNativePG manifests in `apps/overlays/jotunheim/postgres-replica.yaml`, configured with `spec.replica.enabled: true`:
- Continuously streams transaction logs from the primary cluster.
- Serves read-only analytical and query traffic locally on Jotunheim.
- Promotable to a full independent read-write primary cluster with a single CLI command:
  ```bash
  kubectl --context jotunheim cnpg promote yggdrasil-pg -n storage-system
  kubectl --context jotunheim cnpg promote authentik-pg -n auth-system
  ```

### 2.2 SeaweedFS S3 Object Storage Synchronization
Configured in `apps/overlays/jotunheim/seaweedfs-s3-replication.yaml`:
- Synchronizes `yggdrasil-storage`, `cnpg-backups`, `vault-backups`, and `zulip-uploads` buckets between primary and secondary SeaweedFS filers.
- Runs on a scheduled 15-minute interval with strict Pod Security Standards (PSA Restricted profile, non-root, read-only root filesystem, dropped capabilities).
- Ensures that if the German datacenter experiences catastrophic hardware failure, all uploaded files, user attachments, and encrypted database snapshots exist intact in France.

### 2.3 VictoriaMetrics Dual-Write Telemetry & Global PromQL
Configured in `apps/overlays/jotunheim/monitoring-cross-cluster.yaml`:
- The `VMAgent` operator on each cluster pushes gathered metrics to **both** local TSDB (`vmsingle-yggdrasil-vmsingle.monitoring-system:8429`) and the peer cluster's TSDB across the WireGuard tunnel.
- Fluent Bit similarly forwards log streams to both VictoriaLogs instances.
- Enables single-pane-of-glass observability and prevents metric blind spots during cloud provider networking partitions.

### 2.4 Docker-Mailserver Secondary MX & Dovecot `dsync`
Configured in `apps/overlays/jotunheim/mail-replication.yaml`:
- Jotunheim mail instance is configured as Secondary MX (priority 20) with relay fallback to Yggdrasil (priority 10).
- Dovecot's `dsync` utility synchronizes user mailboxes, flags, and folder structures.
- If Yggdrasil becomes unreachable, external MTAs automatically deliver inbound SMTP mail to Jotunheim (MX 20). Users access Roundcube on Jotunheim with zero missing mail.

### 2.5 RabbitMQ Cross-Cluster Federation
Configured in `apps/overlays/jotunheim/rabbitmq-federation.yaml`:
- Enables the RabbitMQ Federation plugin with an upstream link pointing to `amqp://zulip:***@10.4.0.1:5672/%2F`.
- Applies federation policies to `^task-.*` queues, permitting KEDA background workers on either cluster to consume and balance processing loads across regions.

### 2.6 CoreDNS AXFR Zone Transfers
Configured in `apps/overlays/jotunheim/dns-secondary.yaml`:
- CoreDNS on Jotunheim acts as a secondary authoritative name server for `yggdrasil.local`.
- Whenever DNS records change on Yggdrasil, an RFC 1996 `NOTIFY` triggers an instantaneous AXFR zone transfer.
- Jotunheim pods resolve all cluster and realm endpoints with zero cross-region network latency.

### 2.7 Harbor Cross-Cluster Two-Way OCI Replication
Configured in `scripts/setup-harbor-replication.py`:
- Push-based two-way replication rule mirroring all OCI artifacts, container images, and Helm charts between `registry.yggdrasil.local` and `registry.jotunheim.local:30080`.
- Both clusters maintain a local sovereign image cache, allowing node scaling and pod restarts without external internet dependencies.

---

## 3. Disaster Recovery (DR) Failover Runbook

In the event of an unrecoverable outage at Cloud Provider 1 (e.g. Hetzner datacenter network severance):

### Step 1: Verify Mesh & Peer Status
```bash
# Check Kilo WireGuard connectivity to peer
kubectl --context kind-jotunheim -n vpn-system get peer yggdrasil
```

### Step 2: Promote CloudNativePG Databases to Read-Write
```bash
# Promote storage-system database
kubectl --context kind-jotunheim -n storage-system cnpg promote yggdrasil-pg

# Promote auth-system database
kubectl --context kind-jotunheim -n auth-system cnpg promote authentik-pg

# Verify write capability
kubectl --context kind-jotunheim -n storage-system get cluster yggdrasil-pg
# Status should transition from 'Standby' to 'Cluster in healthy state'
```

### Step 3: Shift External Traffic to Jotunheim Gateway
Update external DNS records (e.g. via Cloudflare, OVH DNS, or BGP Anycast):
- `yggdrasil.local` / `*.yggdrasil.local` A/AAAA records updated to point to Jotunheim Public IP.
- Inbound mail naturally drains to Jotunheim via MX 20.

### Step 4: Resume GitOps on Jotunheim
```bash
# Reconcile GitOps root on Jotunheim
flux --context kind-jotunheim reconcile kustomization apps --with-source
```

All application services (Authentik, Zulip, Roundcube, Forgejo, Web hosting) immediately resume serving user traffic backed by the promoted local PostgreSQL database and replicated S3 storage.
