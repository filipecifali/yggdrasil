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
