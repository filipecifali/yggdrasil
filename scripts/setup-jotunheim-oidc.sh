#!/usr/bin/env bash
# ==============================================================================
# setup-jotunheim-oidc.sh
# Configures kube-apiserver OIDC authentication against Authentik
# on the Jotunheim control-plane node across the Kilo WireGuard mesh.
# ==============================================================================
set -euo pipefail

OIDC_ISSUER="https://auth.yggdrasil.local/application/o/k8s/"
OIDC_CLIENT_ID="kubernetes"
OIDC_CA_FILE="/etc/kubernetes/pki/yggdrasil-ca.crt"
CP="jotunheim-control-plane"

echo "==> 1. Exporting Yggdrasil Root CA certificate from cert-manager..."
TMP_CA="$(mktemp)"
kubectl --context kind-yggdrasil get secret -n cert-manager yggdrasil-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TMP_CA}"

# Fetch Envoy Gateway bifrost ClusterIP dynamically from Yggdrasil
GATEWAY_IP="$(kubectl --context kind-yggdrasil get svc -n envoy-gateway-system envoy-envoy-gateway-system-bifrost-7e8f3d0b -o jsonpath='{.spec.clusterIP}')"
echo "  [OK] Bifrost Ingress ClusterIP on Yggdrasil: ${GATEWAY_IP}"

echo "==> 2. Copying CA and configuring /etc/hosts on ${CP}..."
docker cp "${TMP_CA}" "${CP}:${OIDC_CA_FILE}"
docker exec "${CP}" chmod 644 "${OIDC_CA_FILE}"
rm -f "${TMP_CA}"

docker exec "${CP}" bash -c "
  if grep -q 'auth.yggdrasil.local' /etc/hosts; then
    sed \"s/.*auth.yggdrasil.local/${GATEWAY_IP} auth.yggdrasil.local/\" /etc/hosts > /tmp/hosts.new && cat /tmp/hosts.new > /etc/hosts && rm -f /tmp/hosts.new
  else
    echo '${GATEWAY_IP} auth.yggdrasil.local' >> /etc/hosts
  fi
"
echo "  [OK] Provisioned PKI CA & hosts on ${CP}"

echo "==> 3. Verifying OIDC TLS connectivity from ${CP}..."
docker exec "${CP}" curl --cacert "${OIDC_CA_FILE}" -s \
  "${OIDC_ISSUER}.well-known/openid-configuration" | grep -q "${OIDC_ISSUER}"
echo "  [SUCCESS] OIDC discovery endpoint validated via trusted root CA."

echo "==> 4. Configuring kube-apiserver static pod manifest with OIDC flags on ${CP}..."
docker exec "${CP}" bash -c '
  MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
  BACKUP="/etc/kubernetes/manifests/kube-apiserver.yaml.bak"
  
  if [ ! -f "${BACKUP}" ]; then
    cp "${MANIFEST}" "${BACKUP}"
  fi

  if grep -q "oidc-issuer-url" "${MANIFEST}"; then
    echo "  OIDC flags already present on '${CP}'"
  else
    sed -i "/- kube-apiserver/a \    - --oidc-issuer-url=https://auth.yggdrasil.local/application/o/k8s/\n    - --oidc-client-id=kubernetes\n    - --oidc-username-claim=preferred_username\n    - --oidc-groups-claim=groups\n    - --oidc-ca-file=/etc/kubernetes/pki/yggdrasil-ca.crt" "${MANIFEST}"
    echo "  Injected OIDC flags into kube-apiserver manifest on '${CP}'"
  fi
'

echo "==> 5. Waiting for Jotunheim kube-apiserver to restart and become healthy..."
sleep 5
for i in {1..30}; do
  if kubectl --context kind-jotunheim get nodes >/dev/null 2>&1; then
    READY_NODES="$(kubectl --context kind-jotunheim get nodes --no-headers | grep -c "Ready" || true)"
    if [ "${READY_NODES}" -eq 2 ]; then
      echo "  [SUCCESS] Jotunheim Kubernetes API server is responsive and both nodes are Ready!"
      break
    fi
  fi
  echo "  Waiting for Jotunheim kube-apiserver reconciliation (${i}/30)..."
  sleep 3
done

echo "==> Jotunheim control plane OIDC configuration complete."
