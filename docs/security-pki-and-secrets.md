# Security, PKI & Secret Management (`cert-manager`, `external-secrets`, `vault-system`)

## Purpose
Provides automated X.509 certificate lifecycle management (**`cert-manager`**), centralized encrypted secret storage (**HashiCorp Vault**), declarative secret synchronization (**External Secrets Operator**), and Kubernetes network isolation (**NetworkPolicies** & **Pod Security Admission**).

## Manifests Location
- `infrastructure/base/cert-manager/helmrelease.yaml` — `cert-manager` operator (`enableGatewayAPI: true`)
- `infrastructure/base/external-secrets/helmrelease.yaml` — External Secrets Operator (`installCRDs: true`)
- `apps/base/security/cert-issuers.yaml` — Internal Root CA, `ClusterIssuer`, and TLS `Certificate` resources
- `apps/base/security/vault-helmrelease.yaml` — HashiCorp Vault (`raft` storage + UI) & `HTTPRoute`
- `apps/base/security/cluster-secret-store.yaml` — `ClusterSecretStore/vault-backend` (`external-secrets.io/v1`)
- `apps/base/security/network-policies.yaml` — Ingress restrictions for Vault and PostgreSQL

## Important Configuration

1. **`cert-manager` Internal PKI Hierarchy (`cert-issuers.yaml`)**
   - `ClusterIssuer/yggdrasil-selfsigned-bootstrap` generates a 10-year ECDSA P-256 Root CA (`Certificate/yggdrasil-root-ca`).
   - `ClusterIssuer/yggdrasil-ca` uses that Root CA to issue:
     - `Certificate/bifrost-wildcard-tls` (`envoy-gateway-system`): Covers `yggdrasil.local` and `*.yggdrasil.local`.
     - `Certificate/mail-server-tls` (`mail-system`): Covers `mail.yggdrasil.local` for SMTP STARTTLS and IMAPS.
   - All certificates enforce `privateKey.rotationPolicy: Always` (`ECDSA` `256`).

2. **HashiCorp Vault (`vault-helmrelease.yaml`)**
   - Runs in `vault-system` (*Andvari*) on the `platform` node pool using integrated **Raft** storage (`2Gi` PVC).
   - Exposed via Envoy Gateway at `https://vault.yggdrasil.local` with strict `HSTS`, `X-Frame-Options: DENY`, and `Referrer-Policy: no-referrer` headers.
   - `NetworkPolicy/vault-restricted-ingress` restricts ports `8200`/`8201` strictly to `envoy-gateway-system`, `external-secrets`, `monitoring-system`, and `vault-system`.

3. **External Secrets Operator (`cluster-secret-store.yaml`)**
   - `ClusterSecretStore/vault-backend` (`apiVersion: external-secrets.io/v1`) connects to `http://vault.vault-system.svc.cluster.local:8200` (KV v2 path `secret`) via Kubernetes ServiceAccount authentication (`role: external-secrets`).
