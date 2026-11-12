#!/usr/bin/env bash
# ==============================================================================
# generate-user-kubeconfig.sh
# Generates user kubeconfigs for Yggdrasil cluster access:
#   Mode 1: OIDC Authentication (recommended - browser login via Authentik)
#   Mode 2: Mutual TLS / X509 Client Certificate (offline / automated CI)
#
# Usage:
#   ./scripts/generate-user-kubeconfig.sh oidc <username> [output-kubeconfig]
#   ./scripts/generate-user-kubeconfig.sh cert <username> <group> [output-kubeconfig]
# ==============================================================================
set -euo pipefail

MODE="${1:-oidc}"
USERNAME="${2:-user}"
OUTPUT="${3:-}"

CLUSTER_NAME="yggdrasil"
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo 'https://127.0.0.1:6443')"
OIDC_ISSUER="https://auth.yggdrasil.local/application/o/k8s/"
OIDC_CLIENT_ID="kubernetes"

# Extract Kubernetes cluster CA certificate
CA_DATA="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='kind-${CLUSTER_NAME}')].cluster.certificate-authority-data}")"

if [ -z "${CA_DATA}" ]; then
  # Fallback to direct kind control plane CA
  CA_DATA="$(docker exec yggdrasil-control-plane cat /etc/kubernetes/pki/ca.crt | base64 -w 0)"
fi

if [ "${MODE}" == "oidc" ]; then
  OUTPUT="${OUTPUT:-kubeconfig-${USERNAME}-oidc.yaml}"
  echo "==> Generating OIDC Kubeconfig for '${USERNAME}' (Output: ${OUTPUT})..."

  cat <<EOF > "${OUTPUT}"
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${CA_DATA}
contexts:
  - name: ${USERNAME}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      user: ${USERNAME}
current-context: ${USERNAME}@${CLUSTER_NAME}
users:
  - name: ${USERNAME}
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=${OIDC_ISSUER}
          - --oidc-client-id=${OIDC_CLIENT_ID}
          - --oidc-extra-scope=groups,email,profile
          - --insecure-skip-tls-verify=false
EOF
  echo "  [SUCCESS] OIDC Kubeconfig generated at ${OUTPUT}"
  echo "  User can login using: kubectl --kubeconfig=${OUTPUT} get nodes"

elif [ "${MODE}" == "cert" ]; then
  GROUP="${3:-auditors}"
  OUTPUT="${4:-kubeconfig-${USERNAME}-cert.yaml}"
  echo "==> Generating X509 Client Certificate for user='${USERNAME}', group='${GROUP}' (Output: ${OUTPUT})..."

  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "${TMPDIR}"' EXIT

  # Generate private key and CSR
  openssl ecparam -name prime256v1 -genkey -noout -out "${TMPDIR}/user.key"
  openssl req -new -key "${TMPDIR}/user.key" -out "${TMPDIR}/user.csr" -subj "/CN=${USERNAME}/O=${GROUP}"

  CSR_NAME="user-${USERNAME}-csr"
  kubectl delete csr "${CSR_NAME}" --ignore-not-found >/dev/null 2>&1

  # Create Kubernetes CertificateSigningRequest
  cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: $(base64 -w 0 < "${TMPDIR}/user.csr")
  signerName: kubernetes.io/kube-apiserver-client
  usages:
    - client auth
EOF

  # Approve CSR and retrieve signed cert
  kubectl certificate approve "${CSR_NAME}"
  for i in {1..10}; do
    CERT_DATA="$(kubectl get csr "${CSR_NAME}" -o jsonpath='{.status.certificate}')"
    if [ -n "${CERT_DATA}" ]; then
      break
    fi
    sleep 1
  done

  KEY_DATA="$(base64 -w 0 < "${TMPDIR}/user.key")"

  cat <<EOF > "${OUTPUT}"
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${CA_DATA}
contexts:
  - name: ${USERNAME}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      user: ${USERNAME}
current-context: ${USERNAME}@${CLUSTER_NAME}
users:
  - name: ${USERNAME}
    user:
      client-certificate-data: ${CERT_DATA}
      client-key-data: ${KEY_DATA}
EOF

  kubectl delete csr "${CSR_NAME}" >/dev/null 2>&1
  echo "  [SUCCESS] X509 Certificate Kubeconfig generated at ${OUTPUT}"
  echo "  Test with: kubectl --kubeconfig=${OUTPUT} auth can-i --list"
else
  echo "Invalid mode '${MODE}'. Choose 'oidc' or 'cert'."
  exit 1
fi
