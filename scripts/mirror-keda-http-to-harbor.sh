#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

HARBOR_NS="registry-system"
HARBOR_PORT="18080"
HARBOR_HOST="registry.yggdrasil.local"
HARBOR_PROJECT="library"
HARBOR_USER="admin"
HARBOR_PASS="$(kubectl --context kind-yggdrasil -n "${HARBOR_NS}" get secret harbor-admin-credentials -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)"

echo "==> 1. Opening port-forward to Harbor..."
kubectl --context kind-yggdrasil -n "${HARBOR_NS}" port-forward svc/harbor "${HARBOR_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 3

echo "==> 2. Authenticating crane and helm..."
crane auth login "127.0.0.1:${HARBOR_PORT}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" --insecure
echo "${HARBOR_PASS}" | helm registry login "127.0.0.1:${HARBOR_PORT}" -u "${HARBOR_USER}" --password-stdin --insecure

IMAGES=(
  "ghcr.io/kedacore/http-add-on-interceptor:0.16.0"
  "ghcr.io/kedacore/http-add-on-operator:0.16.0"
  "ghcr.io/kedacore/http-add-on-scaler:0.16.0"
)

for SRC in "${IMAGES[@]}"; do
  IMAGE_NAME="$(basename "${SRC}")"
  DST="127.0.0.1:${HARBOR_PORT}/${HARBOR_PROJECT}/${IMAGE_NAME}"
  echo "==> Mirroring ${SRC} -> ${DST} ..."
  crane copy --insecure --platform linux/amd64 "${SRC}" "${DST}"
done

echo "==> 3. Mirroring Helm chart keda-add-ons-http:0.16.0..."
TMP_DIR="$(mktemp -d)"
helm pull kedacore/keda-add-ons-http --version 0.16.0 -d "${TMP_DIR}"
TGZ_FILE="$(ls "${TMP_DIR}"/*.tgz | head -n 1)"
helm push "${TGZ_FILE}" "oci://127.0.0.1:${HARBOR_PORT}/${HARBOR_PROJECT}" --plain-http
rm -rf "${TMP_DIR}"

echo "==> KEDA HTTP Add-on mirrored successfully to Harbor!"
