# Storage: CloudNativePG & SeaweedFS (`cnpg-system`, `storage-system`)

## Purpose
Provides relational database services (**CloudNativePG** PostgreSQL) and S3-compatible distributed object storage (**SeaweedFS**) in `storage-system` (*Nidavellir*), managed by the CloudNativePG operator in `cnpg-system` (*Urdarbrunnr*).

## Manifests Location
- `infrastructure/base/cnpg-operator/helmrelease.yaml` — CloudNativePG Operator
- `apps/base/storage/postgres-cluster.yaml` — `postgresql.cnpg.io/v1` `Cluster` (`yggdrasil-pg`)
- `apps/base/storage/seaweedfs-helmrelease.yaml` — SeaweedFS `HelmRelease`, S3 IAM `Secret`, and `HTTPRoute`

## Important Configuration

1. **CloudNativePG PostgreSQL (`postgres-cluster.yaml`)**
   - Pinned to `yggdrasil.io/node-pool: platform` (`spec.affinity.nodeSelector`).
   - Enforces **`scram-sha-256`** password encryption and `pg_hba` rules (`hostssl all all all scram-sha-256`).
   - Enables connection/disconnection audit logging (`log_connections: "on"`, `log_disconnections: "on"`).
   - Protected by `NetworkPolicy/postgres-allow-internal-only` (`apps/base/security/network-policies.yaml`).

2. **SeaweedFS Object Storage (`seaweedfs-helmrelease.yaml`)**
   - Deploys **Master** (`2Gi` PVC), **Volume** (`10Gi` PVC), **Filer** (`2Gi` PVC), and **S3 Gateway** (`:8333`) pinned to the `platform` node pool via a Flux Kustomize `postRenderer`.
   - **S3 IAM Authentication Enabled**: Both `s3.enableAuth: true` and `filer.s3.enableAuth: true` reference `Secret/seaweedfs-s3-iam`, preventing unauthenticated bucket access on `https://s3.yggdrasil.local`.

---

## 3. Unified Relational Database Architecture

All relational databases in the Yggdrasil cluster are consolidated onto High-Availability **CloudNativePG PostgreSQL** (`yggdrasil-pg.storage-system.svc.cluster.local:5432`):
- **Forgejo** (`git-system`): Migrated from standalone SQLite to PostgreSQL database `forgejo`. Configured via `apps/base/git/helmrelease.yaml` with credentials dynamically injected via `forgejo-db-secret` ExternalSecret.
- **Roundcube Webmail** (`mail-system`): Migrated from SQLite to PostgreSQL database `roundcube`. Configured in `apps/base/mail/roundcube.yaml` with credentials injected via `roundcube-secret`. All legacy SQLite PVCs and volume mounts (`/var/roundcube/db`) have been eliminated.
- **Zulip Chat** (`chat-system`): Dedicated PostgreSQL instance with automated encrypted cold dumps.
- **Authentik** (`auth-system`): Dedicated CloudNativePG HA cluster `authentik-pg`.

### Benefits of PostgreSQL Consolidation
1. **Zero SQLite File Concurrency / WAL Lock Corruption**: Eliminates single-replica read/write bottlenecks and filesystem locking contention.
2. **Native Continuous Archiving**: CloudNativePG automatically streams WAL logs and takes continuous Barman backups directly into SeaweedFS S3.
3. **High-Availability & Zero-Downtime Failover**: Multi-node replication with automated failover managed by the CNPG operator.

---

## 4. Zero-Knowledge Asymmetric Backup Encryption (Pattern A)

To secure database dumps and Raft snapshots pushed to S3 object storage (SOC 2 CC6.1 / CC6.7 / A1.2 compliance), backups utilize **Pattern A**: a dedicated hardened backup utility container streaming through **`age` asymmetric encryption**.

### Architecture & Trust Boundary

```
+------------------------------------------------------------------------------------------------+
| BACKUP POD (Ephemeral CronJob)                                                                 |
|                                                                                                |
|  +---------------------+        +--------------------+        +-----------------------------+  |
|  | pg_dump / raft snap | =====> |  age -r <pubkey>   | =====> | curl -T - (Streaming HTTP)  |  |
|  +---------------------+ (Pipe) +--------------------+ (Pipe) +-----------------------------+  |
|                                           ^                                  |                 |
|                                           |                                  v                 |
|                            Public Key Only (age1...)            SeaweedFS S3 Bucket            |
|                            (Zero Decryption Risk)              (*.dump.age / *.snap.age)       |
+------------------------------------------------------------------------------------------------+
                                            ^
                                            |
                              +----------------------------+
                              | HashiCorp Vault            |
                              | Private Key (AGE-SECRET-...) |
                              | Restricted to Admins       |
                              +----------------------------+
```

### Components
1. **`backup-tools` Container Image (`scripts/backup-tools/Dockerfile`)**:
   - Base image: `alpine:3.21`.
   - Bundles: `curl`, `postgresql16-client`, `age`, and `ca-certificates`.
   - Security: Runs as non-root user (UID `10001:10001`), read-only root filesystem compatible, zero elevated privileges (`allowPrivilegeEscalation: false`, `drop: [ALL]`).
2. **Vault Asymmetric Key Pair (`secret/storage/backup-encryption`)**:
   - `public_key`: Distributed to cluster namespaces via `apps/base/storage/backup-encryption.yaml` (`ConfigMap/backup-encryption-pubkey`).
   - `private_key`: Strictly confined inside HashiCorp Vault. Ephemeral backup CronJob pods **never** possess or mount the private key.
3. **Encrypted Streaming Pipeline**:
   - Database dumps are piped directly: `pg_dump | age -r "${AGE_RECIPIENT}" | curl -sSfT - https://s3.yggdrasil.local/...`
   - Unencrypted data never touches disk, ephemeral pod storage, or node filesystems.
4. **Environment Isolation**:
   - In production (`apps/base` and `apps/overlays/jotunheim`), backup CronJobs run on automated schedules (`0 3 * * *`).
   - In local development (`apps/overlays/kind`), all CronJobs are suspended (`spec.suspend: true`) via Kustomize patches to avoid unnecessary background job execution.

---

## 5. Disaster Recovery Decryption & Restore Procedure

In the event of database restoration or disaster recovery, authorized administrators retrieve the private key from Vault to decrypt backups:

### Step 1: Retrieve Private Key from Vault
```bash
# Authenticate to Vault
export VAULT_ADDR="https://vault.yggdrasil.local"
vault login -method=oidc

# Fetch the age private key
vault kv get -field=private_key secret/storage/backup-encryption > /tmp/backup-restore.key
chmod 600 /tmp/backup-restore.key
```

### Step 2: Download and Decrypt Backup from SeaweedFS S3
```bash
# Download encrypted backup
curl -k -u "${S3_ACCESS_KEY}:${S3_SECRET_KEY}" \
  https://s3.yggdrasil.local/buckets/database-backups/zulip/zulip-postgres-202611130300.dump.age \
  -o /tmp/zulip-backup.dump.age

# Decrypt using age
age -d -i /tmp/backup-restore.key /tmp/zulip-backup.dump.age > /tmp/zulip-backup.dump
```

### Step 3: Restore to Target Database
```bash
# Restore PostgreSQL dump
pg_restore -h yggdrasil-pg-rw.storage-system.svc.cluster.local -U postgres -d zulip --clean /tmp/zulip-backup.dump

# Securely wipe local keys and plaintexts
shred -u /tmp/backup-restore.key /tmp/zulip-backup.dump /tmp/zulip-backup.dump.age
```
