# Yggdrasil

**Yggdrasil** is a self-contained, sovereign Kubernetes platform reconciled declaratively via **Flux v2 (GitOps)** and simulated locally on **Kind (Kubernetes in Docker)**.

It provides a complete infrastructure and application stack inside Kubernetes:
- **Edge Gateway & CDN Policies:** Envoy Gateway (Gateway API, TLS 1.2/1.3, Brotli/Gzip compression, local rate limiting, security headers)
- **PKI & Secret Management:** `cert-manager` (Internal Root CA & automated TLS rotation), **External Secrets Operator**, and **HashiCorp Vault**
- **Authoritative DNS:** Hardened **CoreDNS** with on-the-fly **DNSSEC** (`ECDSAP256SHA256`), `SPF`, `DKIM`, `DMARC`, `MTA-STS`, `TLS-RPT`, `DANE/TLSA`, `CAA`, and `RFC 8482` `ANY` query blocking
- **Email & Webmail:** **`docker-mailserver`** (Postfix, Dovecot, Rspamd) + **Roundcube Webmail**
- **Databases & Object Storage:** **CloudNativePG (`cnpg`)** PostgreSQL + **SeaweedFS** S3-compatible object storage (with IAM auth)
- **Container & Artifact Registry:** **Harbor** (Container & Helm OCI Registry)
- **Git Forge & CI/CD:** **Forgejo** + **Forgejo Actions Runner**
- **Observability & Autoscaling:** **VictoriaMetrics Operator** (`VMSingle` + `VMAgent`) + **KEDA** Event-Driven Autoscaler
- **Web Hosting:** Unprivileged NGINX hosting & RFC 8461 MTA-STS policy endpoint

## Repository Structure

```text
yggdrasil/
├── clusters/
│   └── kind/                           # Flux entrypoint for the local Kind cluster
│       ├── flux-system/                # Managed by `flux bootstrap github`
│       ├── infrastructure.yaml         # Flux Kustomization for operators, CRDs & namespaces
│       └── apps.yaml                   # Flux Kustomization for realm workloads (depends on infra)
├── infrastructure/
│   ├── base/                           # Namespaces (with PSS labels), HelmRepositories & Operators
│   │   ├── cert-manager/               # cert-manager HelmRelease
│   │   ├── cnpg-operator/              # CloudNativePG Operator HelmRelease
│   │   ├── external-secrets/           # External Secrets Operator HelmRelease
│   │   ├── gateway/                    # Envoy Gateway Controller HelmRelease
│   │   ├── keda/                       # KEDA Operator HelmRelease
│   │   └── victoriametrics-operator/   # VictoriaMetrics Operator HelmRelease
│   └── overlays/
│       └── kind/                       # Kind infrastructure overlay
├── apps/
│   ├── base/                           # Hardened application & service manifests
│   │   ├── dns/                        # CoreDNS HelmRelease, DNSSEC keys & yggdrasil.local zone
│   │   ├── gateway/                    # GatewayClass, Gateway (HTTP/HTTPS) & Edge Traffic Policies
│   │   ├── git/                        # Forgejo HelmRelease, Forgejo Runner & HTTPRoute
│   │   ├── mail/                       # docker-mailserver HelmRelease, Roundcube & HTTPRoute
│   │   ├── monitoring/                 # VictoriaMetrics VMSingle, VMAgent & HTTPRoute
│   │   ├── registry/                   # Harbor HelmRelease & HTTPRoute
│   │   ├── security/                   # PKI ClusterIssuers, HashiCorp Vault, ClusterSecretStore & NetworkPolicies
│   │   ├── storage/                    # CloudNativePG Cluster & SeaweedFS S3 HelmRelease
│   │   └── web/                        # Unprivileged NGINX web server, MTA-STS & KEDA ScaledObject
│   └── overlays/
│       └── kind/                       # Kind NodePort services (Gateway 80/443, DNS 5353, Mail 2525/587/993)
├── docs/
│   └── adding-a-domain.md              # Step-by-step guide for onboarding domains (SPF/DKIM/DMARC/DNSSEC)
├── kind/
│   └── cluster-config.yaml             # Multi-port Kind cluster definition
└── scripts/
    ├── bootstrap-kind.sh               # Helper script to create the Kind cluster & bootstrap Flux
    └── generate-dnssec-key.sh          # Helper script to generate ECDSAP256SHA256 DNSSEC keys & DS records
```

## Realm Namespaces & Endpoints

| Namespace | Norse Realm | Component Scope | Local Hostname / Port |
| :--- | :--- | :--- | :--- |
| `flux-system` | **Yggdrasil Roots** | Flux v2 GitOps Controllers | *(Internal)* |
| `envoy-gateway-system` | **Bifrost** | Envoy Gateway Edge Proxy (HTTP/HTTPS, Brotli/Gzip, Rate Limit) | `:80` / `:443` |
| `cert-manager` | **Heimdall** | Cert-Manager & Yggdrasil Internal Root CA | *(Internal)* |
| `external-secrets` | **Norns** | External Secrets Operator + `ClusterSecretStore` | *(Internal)* |
| `vault-system` | **Andvari** | HashiCorp Vault (Raft Storage + Web UI) | `vault.yggdrasil.local` |
| `cnpg-system` | **Urdarbrunnr** | CloudNativePG Operator | *(Internal)* |
| `monitoring-system` | **Hlidskjalf** | VictoriaMetrics Operator (`VMSingle` + `VMAgent`) | `metrics.yggdrasil.local` |
| `keda-system` | **Sleipnir** | KEDA Event-Driven Autoscaling Operator | *(Internal)* |
| `storage-system` | **Nidavellir** | CNPG PostgreSQL (`yggdrasil-pg`) + SeaweedFS S3 | `s3.yggdrasil.local` |
| `registry-system` | **Sindri** | Harbor Container & Helm OCI Registry | `registry.yggdrasil.local` |
| `git-system` | **Valhalla** | Forgejo Git Server & Forgejo Actions Runner | `git.yggdrasil.local` |
| `dns-system` | **Mimir** | Authoritative CoreDNS (DNSSEC, SPF, DKIM, DMARC, DANE, CAA) | `ns1.yggdrasil.local` (`:5353`) |
| `mail-system` | **Huginn & Muninn** | `docker-mailserver` + Roundcube Webmail | `mail.yggdrasil.local`, `webmail.yggdrasil.local` |
| `web-system` | **Midgard** | Web Hosting & RFC 8461 MTA-STS Policy Host | `yggdrasil.local`, `www.yggdrasil.local`, `mta-sts.yggdrasil.local` |

## Documentation

- [**Adding a Domain & DNS/Email Security Guide (`docs/adding-a-domain.md`)**](docs/adding-a-domain.md) — Step-by-step instructions for configuring DNSSEC, SPF, DKIM, DMARC, MTA-STS, TLS-RPT, DANE/TLSA, and CAA records.

## Quickstart (WSL 2 + Kind + Flux)

1. **Create the local Kind cluster:**
   ```bash
   kind create cluster --config kind/cluster-config.yaml
   ```

2. **Bootstrap Flux v2 with GitHub:**
   ```bash
   export GITHUB_TOKEN=$(gh auth token)
   export GITHUB_USER=$(gh api user -q .login)
   flux bootstrap github \
     --owner="${GITHUB_USER}" \
     --repository=yggdrasil \
     --branch=main \
     --path=./clusters/kind \
     --personal \
     --private=false
   ```

3. **Verify reconciliation:**
   ```bash
   flux get all
   kubectl get ns
   ```
