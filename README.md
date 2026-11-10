# Yggdrasil

**Yggdrasil** is a self-contained, sovereign Kubernetes platform reconciled declaratively via **Flux v2 (GitOps)** and simulated locally on **Kind (Kubernetes in Docker)**.

It provides a complete infrastructure and application stack inside Kubernetes:
- **9-Node HA Topology (Kind):** 3 `control-plane` nodes (stacked `etcd` quorum + HAProxy API load balancer), 3 `platform` worker nodes, and 3 `apps` worker nodes
- **Edge Gateway & CDN Policies:** Envoy Gateway (Gateway API, TLS 1.2/1.3, Brotli/Gzip compression, local rate limiting, security headers)
- **PKI & Secret Management:** `cert-manager` (Internal Root CA & automated TLS rotation), **External Secrets Operator**, and **HashiCorp Vault**
- **Authoritative DNS:** Hardened **CoreDNS** with on-the-fly **DNSSEC** (`ECDSAP256SHA256`), `SPF`, `DKIM`, `DMARC`, `MTA-STS`, `TLS-RPT`, `DANE/TLSA`, `CAA`, and `RFC 8482` `ANY` query blocking
- **Email & Webmail:** **`docker-mailserver`** (Postfix, Dovecot, Rspamd) + **Roundcube Webmail**
- **Databases & Object Storage:** **CloudNativePG (`cnpg`)** PostgreSQL + **SeaweedFS** S3-compatible object storage (with IAM auth)
- **Container & Artifact Registry:** **Harbor** (Container & Helm OCI Registry)
- **Git Forge & CI/CD:** **Forgejo** + **Forgejo Actions Runner** (supports pivoting Flux v2 to reconcile directly from in-cluster Forgejo)
- **Observability & Autoscaling:** **VictoriaMetrics Operator** (`VMSingle` + `VMAgent`) + **KEDA** Event-Driven Autoscaler
- **Web Hosting:** Unprivileged NGINX hosting & RFC 8461 MTA-STS policy endpoint

---

## Local CLI Dependencies

| Tool / Package | Minimum Version | Purpose |
| :--- | :--- | :--- |
| **`docker`** (`docker.io` / `docker-ce`) | `>= 24.0` | Container runtime for running Kind node containers |
| **`kind`** | `>= 0.25.0` | Provisions the local 9-node HA Kubernetes cluster inside Docker |
| **`kubectl`** | `>= 1.31.0` | Kubernetes CLI & Kustomize manifest validation (`kubectl kustomize`) |
| **`flux`** | `>= 2.4.0` | Flux v2 CLI for bootstrapping and managing GitOps reconciliation |
| **`helm`** | `>= 3.14.0` | Mirrors and pushes Helm charts as OCI artifacts into Harbor (`scripts/mirror-charts-to-harbor.sh`) |
| **`crane`** | `>= 0.19.0` | Mirrors upstream container images into Harbor (`scripts/mirror-images-to-harbor.sh`) |
| **`git`** & **`gh`** (GitHub CLI) | `>= 2.40` | Version control & authentication for initial Flux seed bootstrap |
| **`curl`** | Any | Used by `scripts/pivot-to-forgejo.sh` to interact with the Forgejo REST API |
| **`python3`** + **`python3-cryptography`** | `>= 3.10` | Used by `scripts/generate-dnssec-key.sh` to generate RFC 6605 `ECDSAP256SHA256` DNSSEC keys & `DS` records |
| **`dig`** (`dnsutils`) *(Optional)* | Any | Testing CoreDNS authoritative zones, DNSSEC (`+dnssec`), `SPF`, `DKIM`, and `DMARC` records |

> **Note for Multi-Node Kind on Linux / WSL 2:** Running 9 Kind node containers requires `fs.inotify.max_user_instances = 8192` and `fs.inotify.max_user_watches = 1048576` in `sysctl` so `kubelet` does not hit the default 128 instance limit.

---

## Repository Structure

```text
yggdrasil/
├── .forgejo/
│   └── workflows/
│       └── validate-gitops.yaml        # Forgejo Actions CI pipeline run by forgejo-runner on push/PR
├── clusters/
│   └── kind/                           # Flux entrypoint for the local Kind cluster
│       ├── flux-system/                # Managed by `flux bootstrap` (pinned to platform pool)
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
│   └── cluster-config.yaml             # 9-node HA Kind cluster definition (3 CP + 3 platform + 3 apps)
└── scripts/
    ├── bootstrap-kind.sh               # Helper script to create the Kind cluster & bootstrap Flux
    ├── bootstrap-vault-secrets.sh      # Initializes/unseals Vault & seeds all app secrets into Vault KV-v2
    ├── pivot-to-forgejo.sh             # Seeds the repo into in-cluster Forgejo & pivots Flux source
    ├── mirror-images-to-harbor.sh      # Mirrors upstream application images into in-cluster Harbor
    ├── mirror-charts-to-harbor.sh      # Mirrors upstream Helm charts as OCI artifacts into Harbor
    └── generate-dnssec-key.sh          # Helper script to generate ECDSAP256SHA256 DNSSEC keys & DS records
```

## Realm Namespaces, Node Pools & Endpoints

| Namespace | Norse Realm | Node Pool | Component Scope | Local Hostname / Port |
| :--- | :--- | :--- | :--- | :--- |
| `flux-system` | **Yggdrasil Roots** | `platform` | Flux v2 GitOps Controllers | *(Internal)* |
| `envoy-gateway-system` | **Bifrost** | `platform` | Envoy Gateway Edge Proxy (HTTP/HTTPS, Brotli/Gzip, Rate Limit) | `:80` / `:443` |
| `cert-manager` | **Heimdall** | `platform` | Cert-Manager & Yggdrasil Internal Root CA | *(Internal)* |
| `external-secrets` | **Norns** | `platform` | External Secrets Operator + `ClusterSecretStore` | *(Internal)* |
| `vault-system` | **Andvari** | `platform` | HashiCorp Vault (Raft Storage + Web UI) | `vault.yggdrasil.local` |
| `cnpg-system` | **Urdarbrunnr** | `platform` | CloudNativePG Operator | *(Internal)* |
| `monitoring-system` | **Hlidskjalf** | `platform` | VictoriaMetrics Operator (`VMSingle` + `VMAgent`) | `metrics.yggdrasil.local` |
| `keda-system` | **Sleipnir** | `platform` | KEDA Event-Driven Autoscaling Operator | *(Internal)* |
| `storage-system` | **Nidavellir** | `platform` | CNPG PostgreSQL (`yggdrasil-pg`) + SeaweedFS S3 | `s3.yggdrasil.local` |
| `registry-system` | **Sindri** | `platform` | Harbor Container & Helm OCI Registry | `registry.yggdrasil.local` |
| `dns-system` | **Mimir** | `platform` | Authoritative CoreDNS (DNSSEC, SPF, DKIM, DMARC, DANE, CAA) | `ns1.yggdrasil.local` (`:5353`) |
| `git-system` | **Valhalla** | `apps` | Forgejo Git Server & Forgejo Actions Runner | `git.yggdrasil.local` |
| `mail-system` | **Huginn & Muninn** | `apps` | `docker-mailserver` + Roundcube Webmail | `mail.yggdrasil.local`, `webmail.yggdrasil.local` |
| `web-system` | **Midgard** | `apps` | Web Hosting & RFC 8461 MTA-STS Policy Host | `yggdrasil.local`, `www.yggdrasil.local`, `mta-sts.yggdrasil.local` |

---

## In-Cluster GitOps: Pivoting Flux to Self-Hosted Forgejo

Yggdrasil supports a **"Seed & Pivot"** workflow where the cluster initially boots from an external seed repository (or local checkout), brings up **Forgejo** inside `git-system`, pushes the repository into Forgejo, and repoints Flux's `GitRepository/flux-system` to the internal Kubernetes service (`http://forgejo-http.git-system.svc.cluster.local:3000`).

### How to Pivot to In-Cluster Forgejo

Once the cluster and `HelmRelease/forgejo` are running, execute:

```bash
./scripts/pivot-to-forgejo.sh
```

Or run both initial bootstrap and the Forgejo pivot automatically:

```bash
PIVOT_TO_FORGEJO=true ./scripts/bootstrap-kind.sh
```

### Gotchas & Operational Risks of Hosting Git Inside Kind

When running your GitOps source of truth inside the same Kubernetes cluster it manages (especially inside a local Kind environment), keep these four operational caveats in mind:

1. **The Cold-Start "Chicken-and-Egg" Dependency**
   - *Issue:* On a brand-new cluster, Flux cannot pull the manifest that deploys Forgejo *from* Forgejo before Forgejo exists.
   - *Mitigation:* Always keep a bootstrap path (`scripts/bootstrap-kind.sh`) that seeds the cluster from either an external Git remote (`origin`) or local disk (`kubectl apply -k`) before pivoting `GitRepository/flux-system` to the internal Forgejo URL.

2. **Ephemeral Kind Storage (`kind delete cluster` Wipes In-Cluster PVCs)**
   - *Issue:* In Kind, `PersistentVolumeClaim`s (`local-path-storage`) live inside the Kind node Docker containers. Running `kind delete cluster` permanently destroys the Forgejo PVC and any commits that existed *only* inside the cluster.
   - *Mitigation:* `scripts/pivot-to-forgejo.sh` keeps your external Git remote as `origin` and adds the in-cluster Forgejo instance as a separate `cluster` remote (`git push cluster main` & `git push origin main`). Alternatively, configure a **Push Mirror** inside Forgejo Repo Settings so every in-cluster commit is automatically mirrored to an external backup remote.

3. **Self-Bricking via Broken Git Server Manifests**
   - *Issue:* If you push a misconfigured change to `apps/base/git/helmrelease.yaml` (or break `envoy-gateway-system` / `storage-system`) that causes the `forgejo` pod to crash or become unreachable, you cannot `git push` the revert commit to Forgejo to fix it.
   - *Mitigation:* Because you have direct `kubectl` access to the cluster, recover by either rolling back the Helm release (`helm -n git-system rollback forgejo`) or temporarily patching `GitRepository/flux-system` back to your external Git remote until Forgejo is healthy again.

4. **Internal vs. External Git URLs & TLS**
   - *Issue:* If Flux's `GitRepository/flux-system` points to the external ingress URL (`https://git.yggdrasil.local`), any hiccup in **Envoy Gateway**, **CoreDNS**, or **`cert-manager`** TLS renewal will also break Flux's ability to fetch fixes!
   - *Mitigation:* `scripts/pivot-to-forgejo.sh` intentionally points Flux's `GitRepository/flux-system` to the **cluster-internal service URL** (`http://forgejo-http.git-system.svc.cluster.local:3000/...`). This bypasses external DNS, TLS certificates, and the Edge Gateway so Flux can still reconcile and heal the cluster even if ingress or DNS is broken.

---

## Documentation (`docs/`)

See the [**Documentation Index (`docs/README.md`)**](docs/README.md) for detailed guides on each installed component:

- [**Flux v2 & GitOps (`docs/flux-gitops.md`)**](docs/flux-gitops.md) — Reconciliation stages, node-pool pinning, and in-cluster Forgejo pivot
- [**Envoy Gateway (`docs/envoy-gateway.md`)**](docs/envoy-gateway.md) — Gateway API listeners, Brotli/Gzip compression, rate limiting, and TLS 1.2/1.3 hardening
- [**Security, PKI & Secrets (`docs/security-pki-and-secrets.md`)**](docs/security-pki-and-secrets.md) — `cert-manager` Root CA, HashiCorp Vault, External Secrets Operator, and NetworkPolicies
- [**CoreDNS Authoritative DNS (`docs/coredns.md`)**](docs/coredns.md) — Standalone CoreDNS, on-the-fly DNSSEC signing, RFC 8482 `ANY` blocking, and ACLs
- [**Adding a Domain (`docs/adding-a-domain.md`)**](docs/adding-a-domain.md) — Step-by-step runbook for `SPF`, `DKIM`, `DMARC`, `MTA-STS`, `TLS-RPT`, `DANE/TLSA`, `CAA`, and `DNSSEC`
- [**Email & Roundcube Webmail (`docs/mail-and-roundcube.md`)**](docs/mail-and-roundcube.md) — `docker-mailserver` (Postfix/Dovecot/Rspamd) and Roundcube Webmail
- [**Storage: CloudNativePG & SeaweedFS (`docs/storage-cnpg-and-seaweedfs.md`)**](docs/storage-cnpg-and-seaweedfs.md) — PostgreSQL cluster (`scram-sha-256`) and SeaweedFS S3 (IAM auth)
- [**Harbor Registry (`docs/harbor-registry.md`)**](docs/harbor-registry.md) — Container & OCI Helm registry configuration
- [**Forgejo Git & CI/CD Runner (`docs/forgejo-git.md`)**](docs/forgejo-git.md) — Self-hosted Forgejo server and non-root Actions Runner
- [**Observability & Autoscaling (`docs/observability-and-autoscaling.md`)**](docs/observability-and-autoscaling.md) — VictoriaMetrics (`VMSingle`/`VMAgent`) and KEDA `ScaledObject`
- [**Web Hosting & MTA-STS (`docs/web-hosting.md`)**](docs/web-hosting.md) — Unprivileged NGINX (`readOnlyRootFilesystem`) and RFC 8461 MTA-STS policy hosting

## End-to-End Bootstrap Process

Bootstrapping Yggdrasil follows a deterministic 5-stage sequence so that all operators, Vault secrets, Harbor container images, Harbor OCI Helm charts, and in-cluster GitOps/CI components come up cleanly without circular dependencies:

### Stage 1: Provision the 9-Node HA Kind Cluster & Flux v2 Controllers
Creates the 9-node Kind topology (`3 control-plane`, `3 platform`, `3 apps` with `/etc/containerd/certs.d` enabled) and bootstraps Flux v2 into `flux-system` (`./scripts/bootstrap-kind.sh`):
```bash
kind create cluster --config kind/cluster-config.yaml

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

### Stage 2: Initialize HashiCorp Vault & Seed Application Secrets
Once `vault-0` is scheduled in `vault-system`, run `./scripts/bootstrap-vault-secrets.sh`. This script:
1. Initializes Vault (`1` key share, `1` threshold) and stores recovery keys in `vault-system/secret/vault-init-keys`.
2. Unseals `vault-0` so it reaches `1/1 Ready`.
3. Enables the `kv-v2` secrets engine at `secret/` and configures Vault's `kubernetes` auth backend (`role: external-secrets`) for External Secrets Operator (`ClusterSecretStore/vault-backend`).
4. Seeds all 7 application secret paths (`secret/dns/coredns-dnssec-keys`, `secret/registry/harbor-admin`, `secret/storage/seaweedfs-s3-iam`, `secret/storage/postgres-app`, `secret/git/forgejo-admin`, `secret/git/forgejo-runner`, `secret/mail/roundcube`) so every `ExternalSecret` across the cluster reaches `SecretSynced` (`Ready: True`).
```bash
./scripts/bootstrap-vault-secrets.sh
```

### Stage 3: Mirror Container Images into Harbor (`registry.yggdrasil.local/library/*`)
Once `HelmRelease/harbor` is `Ready` in `registry-system`, run `./scripts/mirror-images-to-harbor.sh`. This script:
1. Configures `/etc/containerd/certs.d/registry.yggdrasil.local/hosts.toml` on every Kind node pointing directly to Harbor's `ClusterIP` (`Service/harbor:80`).
2. Uses `crane copy` to mirror all 12 application images (`envoy`, `coredns`, `vault`, `postgresql`, `seaweedfs`, `victoria-metrics`, `vmagent`, `forgejo`, `forgejo-runner`, `docker-mailserver`, `roundcubemail`, `nginx-unprivileged`) into Harbor (`library/*`).
```bash
./scripts/mirror-images-to-harbor.sh
```

### Stage 4: Mirror Helm Charts as OCI Artifacts into Harbor (`oci://harbor.registry-system.svc.cluster.local/library/*`)
Run `./scripts/mirror-charts-to-harbor.sh` to pull all 12 upstream Helm charts and push them as OCI artifacts into Harbor (`library/*`) so Flux `source-controller` reconciles every `HelmRepository` (`type: oci`) locally:
```bash
./scripts/mirror-charts-to-harbor.sh
```

### Stage 5: Pivot Flux to In-Cluster Forgejo & Activate Forgejo Actions Runner
Once `forgejo` and `forgejo-runner-0` are running in `git-system`, run `./scripts/pivot-to-forgejo.sh` to create the `yggdrasil` repository inside Forgejo, push the codebase to the `cluster` remote, and repoint Flux's `GitRepository/flux-system` to `http://forgejo-http.git-system.svc.cluster.local:3000`:
```bash
./scripts/pivot-to-forgejo.sh
```

---

## Using the Forgejo Actions Runner (`.forgejo/workflows/validate-gitops.yaml`)

`StatefulSet/forgejo-runner` (`forgejo-runner-0` in `git-system`) runs as a hardened non-root (`UID 1000`) runner registered against Forgejo in **rootless host-execution mode** (`--labels "ubuntu-latest:host"`).

1. **How Registration Works:**
   - `./scripts/bootstrap-vault-secrets.sh` generates a runner registration token from Forgejo (`gitea actions generate-runner-token`), writes it to Vault (`secret/git/forgejo-runner`), and syncs it via `ExternalSecret/forgejo-runner-secret`.
   - `forgejo-runner-0` registers `/data/.runner` on its persistent volume (`runner-data-forgejo-runner-0`) and polls Forgejo for jobs matching `runs-on: ubuntu-latest`.
2. **Triggering CI Workflows on Push:**
   - Whenever commits are pushed to Forgejo (`git push cluster main`), Forgejo triggers `.forgejo/workflows/validate-gitops.yaml` on `forgejo-runner-0`.
   - The workflow clones the pushed commit from in-cluster Forgejo and validates:
     - **Zero Plaintext Secrets:** Fails if any plaintext `kind: Secret` manifest exists under `apps/` or `infrastructure/` (enforcing Vault + `ExternalSecret`).
     - **Sovereign Harbor Mirrors:** Verifies all `HelmRepository` manifests in `infrastructure/base/helm-repositories.yaml` point to Harbor (`oci://harbor.registry-system.svc.cluster.local/library`).
     - **Kustomize Overlays:** Verifies `kustomization.yaml` trees and renders `infrastructure/overlays/kind` and `apps/overlays/kind` (using `/data/bin/kubectl` if provisioned on the runner PVC).
3. **Provisioning `kubectl` into the Runner PVC for Full Kustomize Rendering:**
   ```bash
   kubectl -n git-system exec -i forgejo-runner-0 -- sh -c 'mkdir -p /data/bin && cat > /data/bin/kubectl && chmod +x /data/bin/kubectl' < "$(which kubectl)"
   ```
