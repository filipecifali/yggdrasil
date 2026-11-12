# Yggdrasil Documentation Index

This directory contains architecture, configuration, and operational guides for every component installed in the **Yggdrasil** Kubernetes cluster.

## Component Guides

| Document | Realm(s) & Namespace(s) | Components Covered |
| :--- | :--- | :--- |
| [**Flux v2 & GitOps (`flux-gitops.md`)**](flux-gitops.md) | *Yggdrasil Roots* (`flux-system`) | Flux v2 controllers, reconciliation dependency order, node-pool pinning, and in-cluster Forgejo pivot |
| [**Envoy Gateway (`envoy-gateway.md`)**](envoy-gateway.md) | *Bifrost* (`envoy-gateway-system`) | Kubernetes Gateway API, HTTP/HTTPS listeners, Brotli/Gzip compression, rate limiting, and TLS 1.2/1.3 hardening |
| [**Security, PKI & Secrets (`security-pki-and-secrets.md`)**](security-pki-and-secrets.md) | *Heimdall, Norns & Andvari* (`cert-manager`, `external-secrets`, `vault-system`) | Internal Root CA, wildcard TLS, HashiCorp Vault, External Secrets Operator, and NetworkPolicies |
| [**CoreDNS Authoritative DNS (`coredns.md`)**](coredns.md) | *Mimir* (`dns-system`) | Standalone CoreDNS, on-the-fly DNSSEC signing, RFC 8482 `ANY` blocking, ACL recursion protection, and zone files |
| [**Adding a Domain (`adding-a-domain.md`)**](adding-a-domain.md) | *Mimir & Huginn/Muninn* (`dns-system`, `mail-system`) | Step-by-step runbook for onboarding a new domain with `SPF`, `DKIM`, `DMARC`, `MTA-STS`, `DANE/TLSA`, `CAA`, and `DNSSEC` |
| [**Email & Roundcube Webmail (`mail-and-roundcube.md`)**](mail-and-roundcube.md) | *Huginn & Muninn* (`mail-system`) | `docker-mailserver` (Postfix, Dovecot, Rspamd) and Roundcube Webmail configuration |
| [**Storage: CloudNativePG & SeaweedFS (`storage-cnpg-and-seaweedfs.md`)**](storage-cnpg-and-seaweedfs.md) | *Urdarbrunnr & Nidavellir* (`cnpg-system`, `storage-system`) | CloudNativePG PostgreSQL cluster (`scram-sha-256`) and SeaweedFS S3 object storage (IAM auth) |
| [**Harbor Registry (`harbor-registry.md`)**](harbor-registry.md) | *Sindri* (`registry-system`) | Harbor container & OCI Helm chart registry, secret management, and Gateway API routing |
| [**Forgejo Git & CI/CD Runner (`forgejo-git.md`)**](forgejo-git.md) | *Valhalla* (`git-system`) | Self-hosted Forgejo Git server, SMTP integration, and non-root Forgejo Actions Runner |
| [**Observability & Autoscaling (`observability-and-autoscaling.md`)**](observability-and-autoscaling.md) | *Hlidskjalf & Sleipnir* (`monitoring-system`, `keda-system`) | VictoriaMetrics (`VMSingle`, `VMAgent`), Grafana dashboards, Node Exporter, Kube-State-Metrics, VictoriaLogs, Fluent Bit log aggregation, and KEDA event-driven autoscaling |
| [**Alerting & Zulip Notifications (`vmalert-and-zulip-alerts.md`)**](vmalert-and-zulip-alerts.md) | *Hlidskjalf & Folkvangr* (`monitoring-system`, `chat-system`) | VMAlert rule evaluation (`VMRule`), Alertmanager routing, and threaded notifications in Zulip |
| [**Web Hosting & MTA-STS (`web-hosting.md`)**](web-hosting.md) | *Midgard* (`web-system`) | Unprivileged NGINX hosting, read-only root filesystem, RFC 8461 MTA-STS policy hosting, and edge headers |
| [**Authentik Identity Provider (`authentik-identity.md`)**](authentik-identity.md) | *Gladsheim* (`auth-system`) | Authentik 2026.8+ (Redis-less), dedicated CloudNativePG database, HashiCorp Vault secrets, Envoy Gateway API routing, and sovereign Harbor mirroring |
| [**Zulip Threaded Team Chat (`zulip-chat.md`)**](zulip-chat.md) | *Folkvangr* (`chat-system`) | Self-hosted Zulip threaded team chat, PostgreSQL 14, RabbitMQ, Memcached, Redis, Vault secrets, and Gateway API routing |\n| [**Kilo WireGuard Mesh (`kilo-vpn-mesh.md`)**](kilo-vpn-mesh.md) | *Niflheim* (`vpn-system`) | Kilo WireGuard mesh overlay, multi-cluster peering (`Peer` CRDs), cross-cluster pod/service routing |

## Operational Runbooks

| Document | Purpose |
| :--- | :--- |
| [**Kubernetes v1.37 & Kind v0.33 Upgrade (`kubernetes-1.37-upgrade.md`)**](kubernetes-1.37-upgrade.md) | Full procedures, root cause analyses, and operational steps for upgrading Kind, node runtimes, bootstrapping sovereign Harbor OCI mirrors, and establishing Kilo WireGuard mesh |
