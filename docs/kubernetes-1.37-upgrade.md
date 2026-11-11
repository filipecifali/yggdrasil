# Kubernetes v1.37 & Kind v0.33 Upgrade Runbook

This document details the procedures, architecture changes, and lessons learned from upgrading the **Yggdrasil** (9-node HA) and **Jotunheim** (2-node) clusters to **Kubernetes v1.37.0** using **Kind v0.33.0**, eliminating version skew against `kubectl` v1.37.2, and re-establishing the sovereign Harbor OCI registry, HashiCorp Vault secrets engine, and Kilo WireGuard cross-cluster mesh.

---

## 1. Upgrade Background & Motivation

### Version Skew & Component Alignment
Prior to the upgrade, the local workstation environment was running **Kind v0.27.0** with Kubernetes **v1.32.x**, while the installed `kubectl` client was **v1.37.2**. According to the official Kubernetes skew policy, a client should not be more than one minor version ahead of the apiserver.

| Component | Pre-Upgrade | Post-Upgrade | Notes |
| :--- | :--- | :--- | :--- |
| **Kind CLI** | `v0.27.0` | **`v0.33.0`** | Official Kind binary compiled with Go 1.26.7 |
| **Kubernetes Control-Plane** | `v1.32.2` | **`v1.37.0`** | `kindest/node:v1.37.0` |
| **`kubectl` Client** | `v1.37.2` | **`v1.37.2`** | Zero version skew against apiserver |
| **Node Base OS** | Debian 12 (Bookworm) | **Debian 13 (Trixie)** | Modern glibc, kernel tooling |
| **Container Runtime** | containerd 1.7.x | **containerd 2.3.4** | Native `certs.d` registry configuration |
| **Host Kernel** | Linux 6.18.x-microsoft-standard-WSL2 | Linux 6.18.x-microsoft-standard-WSL2 | In-tree Linux kernel WireGuard module |

---

## 2. Pre-Upgrade Backup Procedure

Before destroying the previous clusters, an automated snapshot of all stateful components was created and verified:

```
backups/<timestamp>/
├── vault/
│   ├── vault-raft.snap            # 27KB binary Raft snapshot
│   ├── vault-init-keys.yaml       # Shamir unseal keys & root token
│   └── secret_*.json              # Raw JSON exports of all 7 seeded application secrets
├── pki/
│   └── yggdrasil-root-ca-secret.yaml # Internal cert-manager Root CA certificate & private key
├── postgres/
│   └── yggdrasil-pg-dumpall.sql   # CloudNativePG logical cluster dump
├── git/
│   └── forgejo-backup.tar.gz      # Forgejo SQLite database & app.ini configuration
├── mail/
│   └── roundcube.tar.gz           # Roundcube SQLite database & session keyring
└── kilo-*.txt                     # Pre-upgrade WireGuard public keys & endpoints
```

---

## 3. Cluster Recreation (Kubernetes v1.37.0)

### Primary Cluster: `yggdrasil` (9-Node HA)
Configured via `kind/cluster-config.yaml`:
- **Image**: `kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5`
- **Topology**:
  - `3 control-plane` nodes (stacked etcd + HA apiserver via Kind HAProxy load-balancer)
  - `3 platform` worker nodes (`yggdrasil.io/node-pool: platform`)
  - `3 apps` worker nodes (`yggdrasil.io/node-pool: apps`)
- **Networking**:
  - Pod CIDR: `10.244.0.0/16`
  - Service CIDR: `10.96.0.0/12`
  - Kilo Mesh Subnet: `10.4.0.0/16`
  - WireGuard Port: `51820/UDP` (HostNetwork)

### Secondary Cluster: `jotunheim` (2-Node)
Configured via `kind/cluster-jotunheim.yaml`:
- **Topology**: `1 control-plane` + `1 worker`
- **Networking**:
  - Pod CIDR: `10.245.0.0/16`
  - Service CIDR: `10.112.0.0/12`
  - Kilo Mesh Subnet: `10.5.0.0/16`

```bash
# Cluster creation commands
kind create cluster --name yggdrasil --config kind/cluster-config.yaml
kind create cluster --name jotunheim --config kind/cluster-jotunheim.yaml
```

---

## 4. Sovereign Harbor & Vault Bootstrapping Pattern

### The Chicken-and-Egg Challenge
The sovereign cluster policy dictates that all Helm charts and images must be pulled strictly from the internal Harbor registry (`oci://harbor.registry-system.svc.cluster.local/library`). On a clean cluster recreation, Harbor does not yet exist, creating a circular dependency.

### Resolution Sequence
```
+-------------------------------------------------------------------------------+
| 1. Suspend Flux Kustomizations ('infrastructure' & 'apps')                    |
|    flux suspend kustomization infrastructure && flux suspend kustomization apps|
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| 2. Apply Upstream Repositories Temporarily                                     |
|    Let Helm Controller pull cert-manager, external-secrets, vault, and harbor  |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| 3. Unseal Vault & Seed Secrets                                                |
|    Execute ./scripts/bootstrap-vault-secrets.sh                               |
|    -> Restores unseal key, enables KV-v2 at secret/, configures k8s auth role |
|    -> Populates registry-system/harbor-admin-credentials ExternalSecret       |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| 4. Mirror Application Images & Helm Charts to Harbor                          |
|    Execute ./scripts/mirror-images-to-harbor.sh (13 container images via Crane)|
|    Execute ./scripts/mirror-charts-to-harbor.sh (12 Helm charts via Helm OCI) |
+-------------------------------------------------------------------------------+
                                        |
                                        v
+-------------------------------------------------------------------------------+
| 5. Switch to Sovereign OCI Repositories & Resume Flux                          |
|    kubectl apply -f infrastructure/base/helm-repositories.yaml                |
|    flux resume kustomization infrastructure && flux resume kustomization apps |
+-------------------------------------------------------------------------------+
```

---

## 5. Critical Fixes Identified & Resolved

### 1. `docker-mailserver` CrashLoopBackOff: Declarative Accounts Schema
- **Root Cause**: The upstream `docker-mailserver` chart (v4.2.4) expects the `configMaps` key (plural) with explicit sub-objects (`create: true`, `path: ...`, and `data: ...`). The existing `helmrelease.yaml` had `configMap:` (singular) without `create: true`, causing the chart to skip creating `postfix-accounts-cf`. Docker-Mailserver exited with `Failed to start accounts provisioning because no accounts were provided - Dovecot could not be started!`.
- **Resolution**: Updated `apps/base/mail/helmrelease.yaml`:
  ```yaml
  configMaps:
    postfix-accounts.cf:
      create: true
      path: postfix-accounts.cf
      data: |
        postmaster@yggdrasil.local|{SHA512-CRYPT}...
    postfix-virtual.cf:
      create: true
      path: postfix-virtual.cf
      data: |
        admin@yggdrasil.local postmaster@yggdrasil.local
  ```

### 2. Multi-Control-Plane Containerd Configuration Skips Load-Balancer
- **Root Cause**: `kind get nodes --name yggdrasil` returns `yggdrasil-external-load-balancer` (the HAProxy load balancer container). Attempting to configure `/etc/containerd/certs.d/` inside this container failed with `systemctl: executable file not found in $PATH` because it runs HAProxy on Alpine without containerd or systemd.
- **Resolution**: Updated `scripts/mirror-images-to-harbor.sh` to skip load-balancer nodes:
  ```bash
  for NODE in $(kind get nodes --name "${CLUSTER_NAME}"); do
    if [[ "${NODE}" == *load-balancer* ]]; then
      continue
    fi
    # Configure containerd hosts.toml ...
  done
  ```

### 3. Helm v3 Release State Healing After Image Pull Timeouts
- **Root Cause**: When Helm charts initially deployed while images were still being mirrored, releases timed out waiting for pods and were recorded as `STATUS: failed` in Helm secret storage (`sh.helm.release.v1.<release>.v1`). Even when pods later became healthy, Helm rejected subsequent idempotent installs.
- **Resolution**: Updated the internal Helm secret state JSON to `deployed` for `harbor`, `seaweedfs`, and `forgejo`, allowing Flux's `helm-controller` to immediately take over and reconcile them to `Ready: True`.

---

## 6. Kilo WireGuard Cross-Cluster Peering

### WireGuard Public Key Derivation via Curve25519
Kilo generates a random WireGuard private key at `/var/lib/kilo/key` on each node. The public key was derived using Curve25519 (X25519) raw byte serialization:

- **Yggdrasil Leader (`yggdrasil-control-plane`)**:
  - Container IPv4: `172.18.0.6`
  - Public Key: `8S7qMbDouP6/uA42RGFDy1TWmD1U5Oi4RS+bx/5iygM=`
- **Jotunheim Leader (`jotunheim-control-plane`)**:
  - Container IPv4: `172.18.0.13`
  - Public Key: `1QR22GbNQH5CiaTWptZ1anMZgqk/yc+I93GTTKuzBgY=`

### Peer Resource Declarations
Applied `infrastructure/base/kilo/peer-jotunheim.yaml` on `yggdrasil` and `clusters/jotunheim/peer-yggdrasil.yaml` on `jotunheim`:

```yaml
# On Yggdrasil pointing to Jotunheim:
apiVersion: kilo.squat.ai/v1alpha1
kind: Peer
metadata:
  name: jotunheim
spec:
  publicKey: 1QR22GbNQH5CiaTWptZ1anMZgqk/yc+I93GTTKuzBgY=
  endpoint:
    dnsOrIP:
      ip: 172.18.0.13
    port: 51820
  allowedIPs:
    - 10.245.0.0/16
    - 10.112.0.0/12
    - 10.5.0.0/16
```

### Verification & Kernel Routes
Kilo automatically injected the static WireGuard routes into the kernel on both sides:
```
# yggdrasil-control-plane ip route:
10.4.0.0/16 dev kilo0 proto kernel scope link src 10.4.0.1 
10.5.0.0/16 dev kilo0 proto static src 172.18.0.6 
10.112.0.0/12 dev kilo0 proto static src 172.18.0.6 
10.245.0.0/16 dev kilo0 proto static src 172.18.0.6 

# jotunheim-control-plane ip route:
10.4.0.0/16 dev kilo0 proto static src 172.18.0.13 
10.5.0.0/16 dev kilo0 proto kernel scope link src 10.5.0.1 
10.96.0.0/12 dev kilo0 proto static src 172.18.0.13 
10.244.0.0/16 dev kilo0 proto static src 172.18.0.13 
```

### End-to-End Test Results
- **Pod-to-Pod**: `timeout 3 bash -c 'cat < /dev/null > /dev/tcp/10.245.0.2/53'` -> `SUCCESS: Connected to Jotunheim Pod 10.245.0.2:53 over kilo0 WireGuard tunnel!`
- **Service ClusterIP (Yggdrasil -> Jotunheim)**: Connected to `10.112.0.10:53` -> `SUCCESS`
- **Reverse Service ClusterIP (Jotunheim -> Yggdrasil)**: Connected to `10.96.0.10:53` -> `SUCCESS`

---

## 7. Cluster Health Checklist

| Component | Namespace | Verification Command | Expected Status |
| :--- | :--- | :--- | :--- |
| **Nodes** | Cluster | `kubectl get nodes` | 9/9 `Ready` (v1.37.0) |
| **Flux Controllers** | `flux-system` | `flux get kustomizations` | 3/3 `Ready: True` |
| **Helm Releases** | All | `helm list -A` | 12/12 `deployed` |
| **HashiCorp Vault** | `vault-system` | `kubectl -n vault-system exec vault-0 -- vault status` | `sealed: false` |
| **External Secrets** | All | `kubectl get externalsecrets -A` | 7/7 `SecretSynced: True` |
| **Harbor Sovereign Registry** | `registry-system` | `kubectl -n registry-system get pods` | 8/8 `Running` |
| **WireGuard Mesh** | `vpn-system` | `kubectl -n vpn-system get pods` | 9/9 `Running` |
| **Mail Server** | `mail-system` | `kubectl -n mail-system get pods` | `docker-mailserver` 1/1 `Running` |
| **Cross-Cluster Peering** | `vpn-system` | `docker exec yggdrasil-control-plane ip route \| grep kilo0` | All 4 remote CIDRs present |
