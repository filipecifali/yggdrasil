#!/usr/bin/env bash
# ==============================================================================
# setup-control-plane-oidc.sh
# Configures kube-apiserver OIDC authentication against Authentik
# on all Kind control-plane nodes.
# ==============================================================================
set -euo pipefail

OIDC_ISSUER="https://auth.yggdrasil.local/application/o/k8s/"
OIDC_CLIENT_ID="kubernetes"
OIDC_CA_FILE="/etc/kubernetes/pki/yggdrasil-ca.crt"

CONTROL_PLANES=(
  "yggdrasil-control-plane"
  "yggdrasil-control-plane2"
  "yggdrasil-control-plane3"
)

echo "==> 1. Exporting Yggdrasil Root CA certificate from cert-manager..."
TMP_CA="$(mktemp)"
kubectl get secret -n cert-manager yggdrasil-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TMP_CA}"

# Fetch Envoy Gateway bifrost ClusterIP dynamically
GATEWAY_IP="$(kubectl get svc -n envoy-gateway-system envoy-envoy-gateway-system-bifrost-7e8f3d0b -o jsonpath='{.spec.clusterIP}')"
echo "  [OK] Bifrost Ingress ClusterIP: ${GATEWAY_IP}"

echo "==> 2. Copying CA and configuring /etc/hosts on control plane nodes..."
for CP in "${CONTROL_PLANES[@]}"; do
  docker cp "${TMP_CA}" "${CP}:${OIDC_CA_FILE}"
  docker exec "${CP}" chmod 644 "${OIDC_CA_FILE}"

  # Ensure auth.yggdrasil.local resolves to Envoy bifrost clusterIP
  docker exec "${CP}" bash -c "
    if grep -q 'auth.yggdrasil.local' /etc/hosts; then
      sed -i 's/.*auth.yggdrasil.local/${GATEWAY_IP} auth.yggdrasil.local/' /etc/hosts
    else
      echo '${GATEWAY_IP} auth.yggdrasil.local' >> /etc/hosts
    fi
  "
  echo "  [OK] Provisioned PKI CA & hosts on ${CP}"
done
rm -f "${TMP_CA}"

echo "==> 3. Verifying OIDC TLS connectivity from primary control plane..."
docker exec yggdrasil-control-plane curl --cacert "${OIDC_CA_FILE}" -s \
  "${OIDC_ISSUER}.well-known/openid-configuration" | grep -q "${OIDC_ISSUER}"
echo "  [SUCCESS] OIDC discovery endpoint validated via trusted root CA."

echo "==> 4. Configuring kube-apiserver static pod manifest with OIDC flags on control planes..."
for CP in "${CONTROL_PLANES[@]}"; do
  echo "  Configuring ${CP}..."
  docker exec "${CP}" bash -c '
    MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
    BACKUP="/etc/kubernetes/manifests/kube-apiserver.yaml.bak"
    
    if [ ! -f "${BACKUP}" ]; then
      cp "${MANIFEST}" "${BACKUP}"
    fi

    # Check if OIDC flags are already present
    if grep -q "oidc-issuer-url" "${MANIFEST}"; then
      echo "  OIDC flags already present on '${CP}'"
    else
      # Add flags right after - kube-apiserver
      sed -i "/- kube-apiserver/a \    - --oidc-issuer-url=https://auth.yggdrasil.local/application/o/k8s/\n    - --oidc-client-id=kubernetes\n    - --oidc-username-claim=preferred_username\n    - --oidc-groups-claim=groups\n    - --oidc-ca-file=/etc/kubernetes/pki/yggdrasil-ca.crt" "${MANIFEST}"
      echo "  Injected OIDC flags into kube-apiserver manifest on '${CP}'"
    fi
  '
done

echo "==> 5. Waiting for kube-apiserver pods to restart and become healthy..."
sleep 5
for i in {1..30}; do
  if kubectl get nodes >/dev/null 2>&1; then
    READY_NODES="$(kubectl get nodes --no-headers | grep -c "Ready" || true)"
    if [ "${READY_NODES}" -eq 9 ]; then
      echo "  [SUCCESS] Kubernetes API server is responsive and all 9 nodes are Ready!"
      break
    fi
  fi
  echo "  Waiting for kube-apiserver reconciliation (${i}/30)..."
  sleep 3
done

echo "==> Control plane OIDC configuration complete."
