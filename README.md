# Yggdrasil

**Yggdrasil** is a self-contained Kubernetes platform designed to run a complete sovereign infrastructure stack—including **Authoritative/Internal DNS**, **Email (SMTP/IMAP)**, and **Web Hosting (Ingress & TLS)**—reconciled declaratively via **Flux v2 (GitOps)** and tested locally on **Kind (Kubernetes in Docker)**.

## Repository Structure

```text
yggdrasil/
├── clusters/
│   └── kind/                     # Flux entrypoint for the local Kind cluster
│       ├── flux-system/          # Managed by `flux bootstrap github`
│       ├── infrastructure.yaml   # Flux Kustomization for core cluster infra
│       └── apps.yaml             # Flux Kustomization for DNS, Mail, and Web apps
├── infrastructure/
│   ├── base/                     # Shared namespaces, HelmRepositories, controllers
│   └── overlays/
│       └── kind/                 # Kind-specific infrastructure patches
├── apps/
│   ├── base/                     # Base manifests for DNS, Email, and Web workloads
│   └── overlays/
│       └── kind/                 # Kind-specific workload overrides
├── kind/
│   └── cluster-config.yaml       # Multi-port Kind cluster definition (HTTP/S, DNS, Mail)
└── scripts/
    └── bootstrap-kind.sh         # Helper script to create the Kind cluster & bootstrap Flux
```

## Realm Namespaces

| Namespace | Norse Realm / Role | Component Scope |
| :--- | :--- | :--- |
| `flux-system` | **Yggdrasil Roots** | Flux v2 GitOps controllers |
| `ingress-nginx` | **Bifrost** | Edge routing & HTTP/HTTPS ingress |
| `dns-system` | **Mimir** | Self-hosted DNS services |
| `mail-system` | **Huginn & Muninn** | Self-hosted Email (SMTP /Submission / IMAPS) |
| `web-system` | **Midgard** | Web hosting & applications |

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
