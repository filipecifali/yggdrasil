#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

HARBOR_NS="registry-system"
HARBOR_OCI_HOST="127.0.0.1:18080"
HARBOR_PROJECT="library"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-$(kubectl -n "${HARBOR_NS}" get secret harbor-admin-credentials -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)}"

# Ensure helm v3 CLI is installed in ~/.local/bin
if ! command -v helm >/dev/null 2>&1; then
  echo "==> Installing helm to ~/.local/bin/helm..."
  mkdir -p "${HOME}/.local/bin"
  TMP_HELM="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/helm-v3.17.1-linux-amd64.tar.gz" | tar -xz -C "${TMP_HELM}"
  mv "${TMP_HELM}/linux-amd64/helm" "${HOME}/.local/bin/helm"
  chmod +x "${HOME}/.local/bin/helm"
  rm -rf "${TMP_HELM}"
fi

echo "==> Waiting for Harbor deployment in '${HARBOR_NS}' to become Ready..."
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-core --timeout=300s
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-registry --timeout=300s
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-nginx --timeout=300s

# Ensure harbor-core EXT_ENDPOINT uses http:// so its /v2/ Bearer token realm works over HTTP ClusterIP & port-forward
CURRENT_EXT="$(kubectl -n "${HARBOR_NS}" get cm harbor-core -o jsonpath='{.data.EXT_ENDPOINT}')"
if [[ "${CURRENT_EXT}" == https://* ]]; then
  echo "==> Updating harbor-core EXT_ENDPOINT to http://registry.yggdrasil.local for internal HTTP pulls..."
  kubectl -n "${HARBOR_NS}" patch cm harbor-core --type merge -p '{"data":{"EXT_ENDPOINT":"http://registry.yggdrasil.local"}}'
  kubectl -n "${HARBOR_NS}" rollout restart deployment/harbor-core deployment/harbor-registry
  kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-core --timeout=300s
  kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-registry --timeout=300s
fi

echo "==> Opening local port-forward to Harbor (${HARBOR_NS}/svc/harbor)..."
kubectl -n "${HARBOR_NS}" port-forward svc/harbor 18080:80 >/dev/null 2>&1 &
PF_PID=$!
WORK_DIR="$(mktemp -d)"
trap 'kill ${PF_PID} 2>/dev/null || true; rm -rf "${WORK_DIR}"' EXIT
sleep 3

echo "==> Logging into Harbor OCI registry via helm..."
echo "${HARBOR_PASS}" | helm registry login "${HARBOR_OCI_HOST}" -u "${HARBOR_USER}" --password-stdin --insecure

# Format: TYPE|REPO_URL|CHART_NAME|VERSION
CHARTS=(
  "oci|oci://docker.io/envoyproxy|gateway-helm|1.10.0"
  "http|https://charts.jetstack.io|cert-manager|v1.21.3"
  "http|https://charts.external-secrets.io|external-secrets|0.20.4"
  "http|https://helm.releases.hashicorp.com|vault|0.34.1"
  "http|https://cloudnative-pg.github.io/charts|cloudnative-pg|0.29.1"
  "http|https://victoriametrics.github.io/helm-charts/|victoria-metrics-operator|0.68.2"
  "http|https://kedacore.github.io/charts|keda|2.21.0"
  "oci|oci://code.forgejo.org/forgejo-helm|forgejo|12.5.4"
  "http|https://seaweedfs.github.io/seaweedfs/helm|seaweedfs|4.53.0"
  "http|https://helm.goharbor.io|harbor|1.19.4"
  "http|https://coredns.github.io/helm|coredns|1.50.4"
  "http|https://docker-mailserver.github.io/docker-mailserver-helm|docker-mailserver|4.2.4"
)

for ENTRY in "${CHARTS[@]}"; do
  IFS='|' read -r REPO_TYPE REPO_URL CHART_NAME CHART_VER <<< "${ENTRY}"
  echo "==> Mirroring Helm chart ${CHART_NAME}:${CHART_VER} from ${REPO_URL} -> oci://registry.yggdrasil.local/${HARBOR_PROJECT}/${CHART_NAME} ..."
  rm -f "${WORK_DIR}"/*.tgz
  if [[ "${REPO_TYPE}" == "oci" ]]; then
    helm pull "${REPO_URL}/${CHART_NAME}" --version "${CHART_VER}" -d "${WORK_DIR}"
  else
    helm pull "${CHART_NAME}" --repo "${REPO_URL}" --version "${CHART_VER}" -d "${WORK_DIR}"
  fi
  TGZ_FILE="$(ls "${WORK_DIR}"/*.tgz | head -n 1)"
  helm push "${TGZ_FILE}" "oci://${HARBOR_OCI_HOST}/${HARBOR_PROJECT}" --plain-http
  if [[ "${CHART_VER}" == v* ]] && command -v crane >/dev/null 2>&1; then
    crane tag --insecure "${HARBOR_OCI_HOST}/${HARBOR_PROJECT}/${CHART_NAME}:${CHART_VER}" "${CHART_VER#v}"
  fi
done

echo "==> All 12 Helm charts mirrored to Harbor OCI registry (oci://harbor.registry-system.svc.cluster.local/${HARBOR_PROJECT})!"
