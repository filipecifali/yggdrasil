#!/usr/bin/env bash
set -euo pipefail

VAULT_NS="vault-system"
VAULT_POD="vault-0"

echo "==> Waiting for Vault pod (${VAULT_NS}/${VAULT_POD}) to be scheduled and running..."
for i in {1..60}; do
  PHASE="$(kubectl -n "${VAULT_NS}" get pod "${VAULT_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${PHASE}" == "Running" ]]; then
    break
  fi
  sleep 2
done

INIT_STATUS="$((kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- vault status -format=json 2>/dev/null || true) | grep -o '"initialized": *[a-z]*' | awk -F: '{gsub(/ /,"",$2); print $2}')"

if [[ "${INIT_STATUS}" != "true" ]]; then
  echo "==> Initializing HashiCorp Vault (${VAULT_NS}/${VAULT_POD})..."
  INIT_JSON="$(kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- vault operator init -key-shares=1 -key-threshold=1 -format=json)"
  UNSEAL_KEY="$(echo "${INIT_JSON}" | grep -A1 '"unseal_keys_b64"' | tail -n1 | tr -d ' ",\r\n')"
  ROOT_TOKEN="$(echo "${INIT_JSON}" | grep '"root_token"' | awk -F'"' '{print $4}' | tr -d '\r\n')"

  kubectl -n "${VAULT_NS}" create secret generic vault-init-keys \
    --from-literal=unseal-key="${UNSEAL_KEY}" \
    --from-literal=root-token="${ROOT_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "==> Vault is already initialized; loading keys from ${VAULT_NS}/secret/vault-init-keys..."
  UNSEAL_KEY="$(kubectl -n "${VAULT_NS}" get secret vault-init-keys -o jsonpath='{.data.unseal-key}' | base64 -d)"
  ROOT_TOKEN="$(kubectl -n "${VAULT_NS}" get secret vault-init-keys -o jsonpath='{.data.root-token}' | base64 -d)"
fi

SEALED_STATUS="$((kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- vault status -format=json 2>/dev/null || true) | grep -o '"sealed": *[a-z]*' | awk -F: '{gsub(/ /,"",$2); print $2}')"
if [[ "${SEALED_STATUS}" == "true" ]]; then
  echo "==> Unsealing Vault (${VAULT_NS}/${VAULT_POD})..."
  kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- vault operator unseal "${UNSEAL_KEY}" >/dev/null
fi

echo "==> Verifying Vault is responsive and unsealed..."
for i in {1..30}; do
  SEALED="$(kubectl -n "${VAULT_NS}" exec "${VAULT_POD}" -- vault status -format=json 2>/dev/null | grep -o '"sealed": *[a-z]*' | awk -F: '{gsub(/ /,"",$2); print $2}' || true)"
  if [[ "${SEALED}" == "false" ]]; then
    echo "==> Vault (${VAULT_NS}/${VAULT_POD}) is unsealed and ready!"
    break
  fi
  sleep 2
done

# Obtain Forgejo runner registration token if Forgejo is running
RUNNER_TOKEN="placeholder-forgejo-runner-token"
if kubectl -n git-system get deploy forgejo >/dev/null 2>&1; then
  GEN_TOKEN="$(kubectl -n git-system exec deploy/forgejo -c forgejo -- gitea actions generate-runner-token 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "${GEN_TOKEN}" ]]; then
    RUNNER_TOKEN="${GEN_TOKEN}"
  fi
fi

echo "==> Configuring Vault KV-v2 engine, Kubernetes Auth role for ESO, and seeding all application secrets..."
kubectl -n "${VAULT_NS}" exec -i "${VAULT_POD}" -- env VAULT_TOKEN="${ROOT_TOKEN}" RUNNER_TOKEN="${RUNNER_TOKEN}" sh -e << 'VAULT_SH'
# Enable KV-v2 secrets engine at secret/
vault secrets enable -path=secret kv-v2 2>/dev/null || true

# Enable & configure Kubernetes Auth method for External Secrets Operator
vault auth enable kubernetes 2>/dev/null || true
vault write auth/kubernetes/config \
  kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443"

vault policy write external-secrets - << 'POLICY'
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY

vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=24h

# 1. DNS (dns-system/coredns-dnssec-keys)
vault kv put secret/dns/coredns-dnssec-keys \
  dnssec.key="yggdrasil.local. IN DNSKEY 257 3 13 DACBOoPnZG6JnE1MUI9PoIjsB7fpUT7QndKGC1eFj6CQOBNWJApsHPNFMGBMAGojUf0b8x95lEVQ3VPg4kKrmw==
" \
  dnssec.private="Private-key-format: v1.3
Algorithm: 13 (ECDSAP256SHA256)
PrivateKey: NLvjUcrYRpjn9HA1kcpyGLO6MRabNsHXbRE3xFVB7dM=
"

# 2. Harbor Registry (registry-system/harbor-admin-credentials)
vault kv put secret/registry/harbor-admin \
  HARBOR_ADMIN_PASSWORD="ChangeMe123!"

# 3. SeaweedFS S3 IAM (storage-system/seaweedfs-s3-iam)
vault kv put secret/storage/seaweedfs-s3-iam \
  seaweedfs_s3_config='{
  "identities": [
    {
      "name": "yggdrasil-s3-admin",
      "credentials": [
        {
          "accessKey": "yggdrasil-local-access-key",
          "secretKey": "yggdrasil-local-secret-key-change-me"
        }
      ],
      "actions": ["Admin", "Read", "List", "Tagging", "Write"]
    }
  ]
}'

# 4. CloudNativePG PostgreSQL App User (storage-system/yggdrasil-pg-app-user)
vault kv put secret/storage/postgres-app \
  username="app" \
  password="ChangeMe123!"

# 5. Forgejo Admin & Runner (git-system/forgejo-admin-secret & forgejo-runner-secret)
vault kv put secret/git/forgejo-admin \
  username="yggdrasil-admin" \
  password="ChangeMe123!" \
  email="admin@yggdrasil.local"

vault kv put secret/git/forgejo-runner \
  runner-token="${RUNNER_TOKEN}"

# 6. Roundcube Webmail DES Key (mail-system/roundcube-secret)
vault kv put secret/mail/roundcube \
  ROUNDCUBEMAIL_DES_KEY="yggdrasil-roundcube-24b!"

# 7. Authentik Identity & DB (auth-system/authentik-secrets & authentik-pg-user)
vault kv put secret/auth/authentik-db \
  username="authentik" \
  password="ChangeMe123!"

vault kv put secret/auth/authentik \
  AUTHENTIK_SECRET_KEY="yggdrasil-authentik-secret-key-production-change-me-0123456789" \
  AUTHENTIK_POSTGRESQL__HOST="authentik-pg-rw.auth-system.svc.cluster.local" \
  AUTHENTIK_POSTGRESQL__NAME="authentik" \
  AUTHENTIK_POSTGRESQL__USER="authentik" \
  AUTHENTIK_POSTGRESQL__PASSWORD="ChangeMe123!" \
  AUTHENTIK_POSTGRESQL__PORT="5432" \
  AUTHENTIK_IN_CLUSTER="true" \
  AUTHENTIK_ERROR_REPORTING__ENABLED="false" \
  AUTHENTIK_EMAIL__HOST="docker-mailserver.mail-system.svc.cluster.local" \
  AUTHENTIK_EMAIL__PORT="25" \
  AUTHENTIK_EMAIL__FROM="authentik@yggdrasil.local"

# 8. Zulip Threaded Chat (chat-system/zulip-secrets)
vault kv put secret/chat/zulip \
  secret-key="yggdrasil-zulip-secret-key-production-change-me-0123456789" \
  postgres-password="ChangeMe123!" \
  rabbitmq-password="ChangeMe123!" \
  memcached-password="ChangeMe123!" \
  redis-password="ChangeMe123!"
VAULT_SH

echo "==> All application secrets stored in HashiCorp Vault (secret/*)!"
