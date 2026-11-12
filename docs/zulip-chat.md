# Zulip Threaded Team Chat — Folkvangr Realm (`chat-system`)

## Purpose
**Zulip** is an open-source, self-hosted team collaboration and threaded chat platform providing structured, topic-based streams as an alternative to Slack. In Yggdrasil, Zulip resides in the **Folkvangr** realm (`chat-system`) and is integrated with HashiCorp Vault, Envoy Gateway (*Bifrost*), and internal CoreDNS (*Mimir*).

## Architecture & Topology

- **Realm:** Folkvangr
- **Namespace:** `chat-system` (Pod Security Standards: `baseline`)
- **Hostnames:** `chat.yggdrasil.local` (Primary), `zulip.yggdrasil.local` (Alias)
- **Node-Pool:** `apps` (`yggdrasil.io/node-pool: apps`)

### Workloads & Subcharts
Zulip 2.4.0 Helm chart deploys the application server alongside its required caching, message queuing, and persistence backends:

| Workload | Image / Version | Description |
| :--- | :--- | :--- |
| **`zulip-server`** (StatefulSet `zulip`) | `zulip-server:12.4-0` | Django application server, Tornado real-time push server, internal Nginx proxy |
| **`zulip-postgresql`** (StatefulSet `zulip-postgresql`) | `zulip-postgresql:14` | Dedicated PostgreSQL 14 instance with Zulip extensions (tsearch_extras, pgcrypto) |
| **`zulip-rabbitmq`** (StatefulSet `zulip-rabbitmq`) | `rabbitmq:4.1.3` | Asynchronous task queue and event bus |
| **`zulip-memcached`** (Deployment `zulip-memcached`) | `memcached:latest` | Session, caching, and Ephemeral state store |
| **`zulip-redis`** (StatefulSet `zulip-redis-master`) | `redis:latest` | In-memory message store and pub/sub broker |

## Sovereign Harbor OCI Mirroring
All container images and the Zulip Helm chart are mirrored into the internal Harbor registry (`registry.yggdrasil.local`):

- **Helm Chart:** `oci://registry.yggdrasil.local/library/zulip:2.4.0` (upstream `oci://ghcr.io/zulip/helm-charts/zulip:2.4.0`)
- **Container Images:**
  - `registry.yggdrasil.local/library/zulip-server:12.4-0`
  - `registry.yggdrasil.local/library/zulip-postgresql:14`
  - `registry.yggdrasil.local/library/rabbitmq:4.1.3`
  - `registry.yggdrasil.local/library/memcached:latest`
  - `registry.yggdrasil.local/library/redis:latest`

Mirroring scripts:
- `scripts/mirror-charts-to-harbor.sh`
- `scripts/mirror-images-to-harbor.sh`

## Security, Secrets & External Secrets
Secrets are stored in HashiCorp Vault under `secret/chat/zulip` and synced to Kubernetes Secret `zulip-secrets` via the External Secrets Operator (`ClusterSecretStore/vault-backend`):

- `secret-key`: Django application secret key
- `postgres-password`: PostgreSQL administrative & user password
- `rabbitmq-password`: RabbitMQ authentication password
- `memcached-password`: Memcached SASL password
- `redis-password`: Redis master authentication password

Seeding script:
```bash
bash scripts/bootstrap-vault-secrets.sh
```

## Gateway API Ingress (`bifrost`)
Zulip is exposed via Gateway API `HTTPRoute` `zulip-web` in namespace `chat-system`:
- **Gateway:** `envoy-gateway-system/bifrost`
- **Hostnames:** `chat.yggdrasil.local`, `zulip.yggdrasil.local`
- **Backend Service:** `zulip:80`
- **TLS Termination:** Wildcard certificate `bifrost-wildcard-tls` issued by internal Root CA.
- **Proxy Trust:** `LOADBALANCER_IPS: "10.0.0.0/8,172.16.0.0/12"` configured in Zulip environment to trust reverse proxy headers (`X-Forwarded-For`, `X-Forwarded-Proto`) from Envoy Gateway.

## Authoritative DNS (`coredns`)
CoreDNS zone `yggdrasil.local` contains CNAME records for Zulip:
```text
chat                IN  CNAME   @
zulip               IN  CNAME   @
```
All records are DNSSEC-signed on-the-fly via CoreDNS `dnssec` plugin.

## Initial Setup & Administration
To complete the initial realm setup:
1. Navigate to `https://chat.yggdrasil.local/new/`.
2. Enter the administrator email address (`admin@yggdrasil.local`).
3. Follow the organization creation wizard to name the realm and invite initial users.

## Alertmanager & Observability Integration

Zulip provides a native incoming webhook integration for Prometheus Alertmanager / VMAlertmanager:
- **Webhook Endpoint:** `http://zulip.chat-system.svc.cluster.local/api/v1/external/alertmanager?api_key=<bot_api_key>&stream=alerts`
- **Topic Threading:** Alerts are grouped and threaded per topic automatically (e.g. topic `{{ .GroupLabels.alertname }}` or `{{ .GroupLabels.namespace }}`).
- **Resolved Notices:** Sends green `[RESOLVED]` notifications to the thread when metric conditions recover.
- **Runbook:** For full setup, Vault secret provisioning, and `VMAlert`/`VMRule` manifests, see [**Alerting Architecture: VMAlert, Alertmanager & Zulip Notifications (`vmalert-and-zulip-alerts.md`)**](vmalert-and-zulip-alerts.md).
