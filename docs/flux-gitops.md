# Flux v2 & GitOps Architecture (`flux-system`)

## Purpose
**Flux v2** is the GitOps engine at the root of Yggdrasil. It continuously watches the Git repository and reconciles cluster state without requiring manual `kubectl apply` or `helm upgrade` commands.

## Manifests Location
- `clusters/kind/flux-system/` — Flux controller definitions (`gotk-components.yaml`), `GitRepository` source (`gotk-sync.yaml`), and `kustomization.yaml`
- `clusters/kind/infrastructure.yaml` — Flux `Kustomization` reconciling `./infrastructure/overlays/kind`
- `clusters/kind/apps.yaml` — Flux `Kustomization` reconciling `./apps/overlays/kind`

## Important Configuration

1. **Two-Stage Reconciliation (`dependsOn`)**
   - `clusters/kind/infrastructure.yaml` reconciles **first** with `wait: true`. It installs all namespaces, `HelmRepository` sources, and cluster-wide operators (`envoy-gateway`, `cert-manager`, `external-secrets`, `cloudnative-pg`, `victoria-metrics-operator`, `keda`).
   - `clusters/kind/apps.yaml` declares `dependsOn: [{ name: infrastructure }]`. This guarantees all CustomResourceDefinitions (CRDs) are registered and ready before Flux applies custom resources (`Gateway`, `Certificate`, `ClusterSecretStore`, `Cluster`, `VMSingle`, `ScaledObject`, etc.).

2. **Platform Node-Pool Pinning**
   - `clusters/kind/flux-system/kustomization.yaml` applies a Kustomize strategic-merge patch to all `Deployment` objects in `flux-system` (`source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller`), pinning them to `yggdrasil.io/node-pool: platform`.

3. **In-Cluster Forgejo Pivot (`scripts/pivot-to-forgejo.sh`)**
   - Once `apps` has deployed **Forgejo** in `git-system`, running `./scripts/pivot-to-forgejo.sh` seeds the repository into Forgejo and updates `GitRepository/flux-system` to pull from `http://forgejo-http.git-system.svc.cluster.local:3000`.
