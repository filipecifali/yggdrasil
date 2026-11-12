# User Management, RBAC & Multi-Tenancy Hardening

This document details the sovereign identity, Role-Based Access Control (RBAC), multi-tenancy quotas, security context hardening, and automated CI/CD testing implemented across the **Yggdrasil** Kubernetes cluster.

---

## 1. Architecture Overview

```
                      +------------------------------------------+
                      | Authentik Identity Provider (Gladsheim)  |
                      |   - OAuth2 / OIDC Provider (k8s-oidc)    |
                      |   - RS256 Asymmetric JWT Signing         |
                      |   - Custom "groups" claim property map   |
                      +------------------------------------------+
                                           |
                +--------------------------+--------------------------+
                |                                                     |
        [kubectl oidc-login]                                   [Kube-apiserver]
        Browser / CLI Login                              Validated via Yggdrasil Root CA
                |                                                     |
                +--------------------------+--------------------------+
                                           |
                                [Kubernetes RBAC]
            +------------------------------+------------------------------+
            |                              |                              |
  [cluster-admins]                  [platform-ops]                    [auditors]
  ClusterRole/cluster-admin    ClusterRole/platform-operator      ClusterRole/view
            |                              |                              |
            +------------------------------+------------------------------+
                                           |
                                   [Tenant Developers]
            +------------------+------------------+------------------+
            |                  |                  |                  |
        [dev-web]          [dev-git]          [dev-chat]         [dev-mail]
       (web-system)       (git-system)       (chat-system)      (mail-system)
      ResourceQuota      ResourceQuota      ResourceQuota      ResourceQuota
        LimitRange         LimitRange         LimitRange         LimitRange
     PSA: Restricted     PSA: Baseline      PSA: Baseline      PSA: Baseline
```

---

## 2. Authentik OIDC Authentication

Kubernetes API authentication is federated to Authentik running in `auth-system`:

### OIDC Provider & Application Specifications
- **Issuer URL**: `https://auth.yggdrasil.local/application/o/k8s/`
- **Client ID**: `kubernetes`
- **Client Type**: `public` (enables CLI / native desktop OAuth2 PKCE without embedded client secrets)
- **Redirect URIs**: `http://localhost:8000`, `http://localhost:18000`, regex: `^http://localhost(:[0-9]+)?/`
- **JWT Signing Algorithm**: `RS256` signed by the cluster root certificate key pair (`jwks_uri: https://auth.yggdrasil.local/application/o/k8s/jwks/`)
- **Scope & Claims Mapping**:
  - `openid`, `email`, `profile`
  - `groups`: Custom ScopeMapping returning `request.user.ak_groups.all()` to populate the standard OIDC `groups` claim in tokens.

### Kube-apiserver Configuration
On each control-plane node (`yggdrasil-control-plane*`), kube-apiserver static pods are provisioned with:
```yaml
- --oidc-issuer-url=https://auth.yggdrasil.local/application/o/k8s/
- --oidc-client-id=kubernetes
- --oidc-username-claim=preferred_username
- --oidc-groups-claim=groups
- --oidc-ca-file=/etc/kubernetes/pki/yggdrasil-ca.crt
```
The trusted Root CA is mounted from `/etc/kubernetes/pki/yggdrasil-ca.crt`, and internal host mapping directs `auth.yggdrasil.local` to Envoy Gateway's cluster service IP (`10.96.58.153`).

---

## 3. RBAC Scoping & Role Matrix

Manifest: [`apps/base/security/rbac-scopes.yaml`](../apps/base/security/rbac-scopes.yaml)

| Group / Identity | Scope | Role Reference | Permissions & Capabilities |
| :--- | :--- | :--- | :--- |
| **`cluster-admins`** | Cluster-Wide | `ClusterRole/cluster-admin` | Full unrestricted administrator access to all APIs, CRDs, and namespaces. |
| **`platform-ops`** | Cluster-Wide | `ClusterRole/yggdrasil-platform-operator` | Dedicated operator role managing nodes, namespaces, storage, networking, certs, monitoring, Vault, and GitOps; pod exec/logs/port-forward across workloads. |
| **`auditors`** | Cluster-Wide | `ClusterRole/view` | Read-only inspection across all namespaces; strictly forbidden from creating, updating, or deleting resources. |
| **`dev-web`** | `web-system` | `ClusterRole/admin` (namespaced `RoleBinding`) | Full administrative control over Midgard web services; access denied to other tenant namespaces. |
| **`dev-git`** | `git-system` | `ClusterRole/admin` (namespaced `RoleBinding`) | Workload and configuration management within Valhalla; access denied to other tenant namespaces. |
| **`dev-chat`** | `chat-system` | `ClusterRole/admin` (namespaced `RoleBinding`) | Workload and configuration management within Folkvangr; access denied to other tenant namespaces. |
| **`dev-mail`** | `mail-system` | `ClusterRole/admin` (namespaced `RoleBinding`) | Workload and configuration management within Huginn & Muninn; access denied to other tenant namespaces. |

---

## 4. Multi-Tenancy Guardrails: Quotas & LimitRanges

Manifests: [`infrastructure/base/resourcequotas.yaml`](../infrastructure/base/resourcequotas.yaml) & [`infrastructure/base/limitranges.yaml`](../infrastructure/base/limitranges.yaml)

### ResourceQuotas
Each tenant namespace is bounded by hard resource ceilings:

```yaml
# Example: Midgard (web-system)
apiVersion: v1
kind: ResourceQuota
metadata:
  name: web-quota
  namespace: web-system
spec:
  hard:
    requests.cpu: "2"
    requests.memory: "2Gi"
    limits.cpu: "4"
    limits.memory: "4Gi"
    requests.storage: "20Gi"
    persistentvolumeclaims: "10"
    pods: "20"
    services: "10"
```

| Namespace | CPU Request / Limit | Memory Request / Limit | Storage Request / PVCs | Pod Limit |
| :--- | :--- | :--- | :--- | :--- |
| `web-system` | 2 cores / 4 cores | 2 GiB / 4 GiB | 20 GiB / 10 PVCs | 20 pods |
| `git-system` | 4 cores / 8 cores | 6 GiB / 12 GiB | 100 GiB / 15 PVCs | 30 pods |
| `chat-system` | 4 cores / 8 cores | 6 GiB / 12 GiB | 50 GiB / 15 PVCs | 25 pods |
| `mail-system` | 3 cores / 6 cores | 4 GiB / 8 GiB | 50 GiB / 10 PVCs | 20 pods |
| `default` | 1 core / 2 cores | 1 GiB / 2 GiB | — | 10 pods |

### LimitRanges
Enforces default container CPU (`50m` request, `500m`-`2000m` limit) and memory (`64Mi`-`128Mi` request, `512Mi`-`2Gi` limit) preventing unstinted container scheduling.

---

## 5. Pod Security Standards (PSA) & SecurityContext Hardening

### Namespace PSA Profiles
In [`infrastructure/base/namespaces.yaml`](../infrastructure/base/namespaces.yaml):
- **`enforce: restricted`**: `cert-manager`, `external-secrets`, `cnpg-system`, `keda-system`, `web-system`.
- **`enforce: baseline`**: `vault-system`, `envoy-gateway-system`, `auth-system`, `git-system`, `storage-system`, `registry-system`, `dns-system`, `chat-system`, `mail-system`.
- **`warn: restricted` / `audit: restricted`**: Applied cluster-wide to generate audit logs and warnings for non-restricted pods.

### Workload SecurityContext Hardening
All platform and custom workloads enforce least privilege:
- **`runAsNonRoot: true`**: Pods run as dedicated non-root service UIDs (e.g. UID 100 for Vault, UID 101 for NGINX unprivileged, UID 1000 for Authentik & Forgejo, UID 65532 for CoreDNS).
- **`allowPrivilegeEscalation: false`**: Disallows `setuid` binary execution.
- **`capabilities.drop: ["ALL"]`**: Strips all Linux kernel capabilities. Only services requiring network socket binding retain `NET_BIND_SERVICE` (e.g. CoreDNS port 53, Roundcube Apache port 80).
- **`seccompProfile.type: RuntimeDefault`**: Restricts syscalls using the container runtime's default seccomp profile.
- **`readOnlyRootFilesystem: true`**: Root filesystem is mounted read-only on `vault-auto-unseal`, `vault-backup-cronjob`, `yggdrasil-web`, and `coredns`.

---

## 6. User Onboarding & Kubeconfig Runbook

Use [`scripts/generate-user-kubeconfig.sh`](../scripts/generate-user-kubeconfig.sh) to provision user credentials:

### Method A: Browser OIDC Login (Recommended)
```bash
./scripts/generate-user-kubeconfig.sh oidc <username> [output-path]
```
1. Generates a kubeconfig configured for `kubectl oidc-login`.
2. When the user executes `kubectl`, their browser opens Authentik:
   `https://auth.yggdrasil.local/application/o/authorize/`
3. After authenticating, Authentik returns an ID token containing their groups.
4. Kube-apiserver validates the token signature against Authentik JWKS and applies the RBAC matrix.

### Method B: Headless X509 Client Certificate (CI/CD & Automation)
```bash
./scripts/generate-user-kubeconfig.sh cert <username> <group> [output-path]

# Example: generate an auditor kubeconfig
./scripts/generate-user-kubeconfig.sh cert auditor-01 auditors /tmp/auditor.kubeconfig
```
1. Generates an EC P-256 private key and CSR (`CN=<username>, O=<group>`).
2. Submits a `CertificateSigningRequest` to the Kubernetes API.
3. Automatically approves the CSR and extracts the cluster-signed client certificate.
4. Assembles a self-contained kubeconfig with zero external dependencies.

---

## 7. Automated Configuration Testing on Forgejo Runners

Workflow: [`.forgejo/workflows/validate-gitops.yaml`](../.forgejo/workflows/validate-gitops.yaml)  
Test Suite: [`scripts/test-cluster-configs.sh`](../scripts/test-cluster-configs.sh)

Every commit and pull request to `main` is automatically evaluated by in-cluster Forgejo Actions Runners across **54 automated test assertions**:

```bash
# Run tests manually at any time:
./scripts/test-cluster-configs.sh
```

### Test Assertions Covered
1. **Shell Scripts (`bash -n`)**: Syntax validation on all `.sh` automation files.
2. **Python Compilation (`py_compile`)**: Syntax check on Authentik and security audit scripts.
3. **Zero Plaintext Secrets**: Rejection of raw `kind: Secret` manifests.
4. **Zero PII**: Rejection of hardcoded personal paths (`/home/...`) or developer credentials.
5. **Harbor OCI Repositories**: Verification that all Helm repositories point to the in-cluster Harbor mirror.
6. **Kustomize Render**: Full dry-run build of all 14 Kustomization overlays and components.
7. **Multi-Tenancy Quotas**: Validation of `ResourceQuota` and `LimitRange` coverage.
8. **PSA Compliance**: Verification of namespace security labels and workload security contexts.
9. **RBAC Least-Privilege Scoping**: Integrity check on ClusterRoleBindings and namespaced developer RoleBindings.
10. **Gateway API Routing**: Validation of HTTPRoute bindings against the Bifrost Gateway.
