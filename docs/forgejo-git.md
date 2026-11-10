# Forgejo Git Server & CI/CD Runner (`git-system`)

## Purpose
**Forgejo** (*Valhalla*) provides a lightweight (~150 MB RAM), 100% open-source Git forge and GitHub Actions-compatible CI/CD system (`Forgejo Actions`) at `https://git.yggdrasil.local`, paired with **`forgejo-runner`**.

## Manifests Location
- `apps/base/git/helmrelease.yaml` — Forgejo `HelmRelease` (`oci://code.forgejo.org/forgejo-helm/forgejo`)
- `apps/base/git/forgejo-runner.yaml` — Non-root `forgejo-runner` `StatefulSet` and token `Secret`
- `apps/base/git/httproute.yaml` — Envoy Gateway `HTTPRoute` for `git.yggdrasil.local`
- `scripts/pivot-to-forgejo.sh` — Script to seed `yggdrasil` into Forgejo and pivot Flux v2 to pull from it

## Important Configuration

1. **Access & Session Hardening (`helmrelease.yaml`)**
   - `service.DISABLE_REGISTRATION: true` and `service.REQUIRE_SIGNIN_VIEW: true` disable public self-registration and anonymous code browsing by default.
   - `security.INSTALL_LOCK: true` and `session.COOKIE_SECURE: true` lock the installer and enforce HTTPS-only session cookies.
   - Outbound notification emails are wired directly to `docker-mailserver.mail-system.svc.cluster.local:25` (`FROM: git@yggdrasil.local`).

2. **Hardened Forgejo Actions Runner (`forgejo-runner.yaml`)**
   - Runs as a `StatefulSet` on the `apps` node pool with a persistent `1Gi` `volumeClaimTemplate` (`/data/.runner` registration survives pod restarts).
   - Enforces `runAsNonRoot: true` (`UID 1000`), `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`, and `automountServiceAccountToken: false`.
