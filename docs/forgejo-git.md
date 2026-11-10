# Forgejo Git Server & CI/CD Runner (`git-system`)

## Purpose
**Forgejo** (*Valhalla*) provides a lightweight (~150 MB RAM), 100% open-source Git forge and GitHub Actions-compatible CI/CD system (**Forgejo Actions**) at `https://git.yggdrasil.local`, paired with a hardened, rootless **`forgejo-runner`** (`StatefulSet/forgejo-runner`).

## Manifests & Workflow Files
- `apps/base/git/helmrelease.yaml` — Forgejo `HelmRelease` (`oci://harbor.registry-system.svc.cluster.local/library/forgejo`) & `ExternalSecret/forgejo-admin-secret`
- `apps/base/git/forgejo-runner.yaml` — Rootless `forgejo-runner` `StatefulSet` & `ExternalSecret/forgejo-runner-secret`
- `apps/base/git/httproute.yaml` — Envoy Gateway `HTTPRoute` for `git.yggdrasil.local`
- `.forgejo/workflows/validate-gitops.yaml` — Forgejo Actions CI pipeline triggered on every `push` and `pull_request` to `main`
- `scripts/pivot-to-forgejo.sh` — Seeds the repository into in-cluster Forgejo and pivots Flux v2 `GitRepository/flux-system` to reconcile from it

---

## Important Configuration

1. **Access & Session Hardening (`helmrelease.yaml`)**
   - Uses `strategy.type: Recreate` so SQLite (`forgejo.db`) and LevelDB queue locks on the `ReadWriteOnce` PVC are cleanly released across rollouts.
   - Administrator credentials (`yggdrasil-admin`) are stored in HashiCorp Vault (`secret/git/forgejo-admin`) and synced via `ExternalSecret/forgejo-admin-secret` (`gitea.admin.existingSecret`).
   - `service.DISABLE_REGISTRATION: true` and `service.REQUIRE_SIGNIN_VIEW: true` disable public self-registration and anonymous code browsing by default.
   - `security.INSTALL_LOCK: true` and `session.COOKIE_SECURE: true` lock the installer and enforce HTTPS-only session cookies.
   - Outbound notification emails are wired directly to `docker-mailserver.mail-system.svc.cluster.local:25` (`FROM: git@yggdrasil.local`).

2. **Hardened Rootless Forgejo Actions Runner (`forgejo-runner.yaml`)**
   - Runs as a `StatefulSet` (`forgejo-runner-0`) on the `apps` node pool with a persistent `1Gi` `volumeClaimTemplate` (`runner-data` mounted at `/data`) so `/data/.runner` registration state persists across pod restarts.
   - Enforces `runAsNonRoot: true` (`UID 1000`), `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, and `automountServiceAccountToken: false`.
   - Registers with `--labels "ubuntu-latest:host"` (**rootless host-execution mode**), allowing workflows targeting `runs-on: ubuntu-latest` to execute directly inside the unprivileged runner container without requiring a privileged Docker-in-Docker (`DinD`) socket.

---

## How to Use the Forgejo Actions Runner

### 1. Automatic Registration via Vault & ESO
During bootstrap (`./scripts/bootstrap-vault-secrets.sh`), the script queries the running Forgejo instance to generate a runner registration token:
```bash
RUNNER_TOKEN="$(kubectl -n git-system exec deploy/forgejo -c forgejo -- gitea actions generate-runner-token | tr -d '\r\n')"
```
It writes that token into HashiCorp Vault at `secret/git/forgejo-runner`, which `ExternalSecret/forgejo-runner-secret` syncs into `git-system`. On startup, `forgejo-runner-0` checks for `/data/.runner`; if not yet registered, it registers against `http://forgejo-http.git-system.svc.cluster.local:3000` with label `ubuntu-latest:host` and starts the runner polling daemon (`forgejo-runner daemon`).

To verify the runner is online and polling Forgejo:
```bash
kubectl -n git-system logs forgejo-runner-0 --tail=20
# Expected output:
# level=info msg="Starting runner daemon"
# level=info msg="runner: yggdrasil-runner, with version: v6.4.0, with labels: [ubuntu-latest], declared successfully"
# level=info msg="[poller 0] launched"
```

### 2. Optional: Provisioning CLI Tools (`/data/bin/kubectl`) on the Runner PVC
Because `/data` is a persistent volume mounted inside `forgejo-runner-0`, any static binary placed in `/data/bin` persists across runner restarts and is automatically added to `PATH` by `.forgejo/workflows/validate-gitops.yaml`:
```bash
kubectl -n git-system exec -i forgejo-runner-0 -- sh -c 'mkdir -p /data/bin && cat > /data/bin/kubectl && chmod +x /data/bin/kubectl' < "$(which kubectl)"
```

### 3. Workflow Template (`.forgejo/workflows/validate-gitops.yaml`)
Forgejo Actions automatically executes workflows stored under `.forgejo/workflows/*.yaml` whenever commits are pushed to the `cluster` remote (`git push cluster main`).

The included template (`.forgejo/workflows/validate-gitops.yaml`) is designed to run **100% air-gapped and self-contained** inside `ubuntu-latest:host` without external GitHub Action dependencies:
1. **Self-Contained Git Checkout:** Clones `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git` at `${GITHUB_SHA}` directly from the in-cluster Forgejo service.
2. **Zero Plaintext Secrets Check:** Fails the build if any plaintext `kind: Secret` manifest is found under `apps/` or `infrastructure/` (enforcing the Vault + `ExternalSecret` policy).
3. **Sovereign Harbor Mirror Check:** Verifies that all `HelmRepository` manifests in `infrastructure/base/helm-repositories.yaml` point to the local Harbor OCI registry (`oci://harbor.registry-system.svc.cluster.local/library`).
4. **Kustomize Overlay Validation:** Verifies all `kustomization.yaml` trees and renders `infrastructure/overlays/kind` and `apps/overlays/kind` via `kubectl kustomize`.
