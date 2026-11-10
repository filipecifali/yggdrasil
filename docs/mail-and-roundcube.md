# Email (`docker-mailserver`) & Roundcube Webmail (`mail-system`)

## Purpose
Provides a full, self-contained email stack (*Huginn & Muninn*) in `mail-system`:
- **`docker-mailserver` (DMS)**: Postfix (SMTP/Submission), Dovecot (IMAP/IMAPS), and Rspamd (spam filtering, DKIM signing, DMARC/SPF verification).
- **Roundcube Webmail**: Browser-based webmail client exposed at `https://webmail.yggdrasil.local`.

## Manifests Location
- `apps/base/mail/helmrelease.yaml` — `docker-mailserver` `HelmRelease` and declarative mailbox/alias config
- `apps/base/mail/roundcube.yaml` — Roundcube `Deployment`, `PersistentVolumeClaim`, `Service`, and `HTTPRoute`
- `apps/overlays/kind/mail-nodeport.yaml` — Exposes SMTP (`30025 -> 2525`), Submission (`30587 -> 587`), and IMAPS (`30993 -> 993`)

## Important Configuration

1. **`docker-mailserver` Hardening & Footprint (`helmrelease.yaml`)**
   - **TLS Integration**: Mounts `Certificate/mail-server-tls` (`certificate: mail-server-tls` issued by `cert-manager`) and enforces `TLS_LEVEL: "modern"`.
   - **Anti-Spoofing & Filtering**: Enables `SPOOF_PROTECTION: "1"` and `ENABLE_RSPAMD: "1"` while disabling heavy ClamAV (`ENABLE_CLAMAV: "0"`) to keep RAM usage around ~350 MB.
   - **Declarative Accounts**: Mailboxes (`postfix-accounts.cf`) and aliases (`postfix-virtual.cf`) are managed declaratively using `{SHA512-CRYPT}` password hashes.
   - **Internal Relay for Cluster Apps**: `PERMIT_DOCKER: "connected-networks"` allows in-cluster services like **Roundcube** and **Forgejo** (`git@yggdrasil.local`) to send mail over `docker-mailserver.mail-system.svc.cluster.local:25`.

2. **Roundcube Webmail (`roundcube.yaml`)**
   - Uses an embedded **SQLite** database stored on a `1Gi` `PersistentVolumeClaim` (`roundcube-db`).
   - Hardened with `automountServiceAccountToken: false`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, and explicit CPU/memory limits on the `apps` node pool.
