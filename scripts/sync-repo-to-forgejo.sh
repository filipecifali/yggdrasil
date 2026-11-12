#!/usr/bin/env bash
# ==============================================================================
# sync-repo-to-forgejo.sh
# Creates and synchronizes yggdrasil repository with in-cluster Forgejo instance
# to trigger automatic CI testing on Forgejo runners.
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

FORGEJO_URL="https://git.yggdrasil.local"
FORGEJO_RESOLVE="git.yggdrasil.local:443:127.0.0.1"

# Fetch credentials from in-cluster secret
FORGEJO_USER="$(kubectl -n git-system get secret forgejo-admin-secret -o jsonpath='{.data.username}' | base64 -d)"
FORGEJO_PASS="$(kubectl -n git-system get secret forgejo-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
REPO_NAME="yggdrasil"

echo "==> 1. Ensuring '${REPO_NAME}' repository exists in Forgejo for user '${FORGEJO_USER}'..."
HTTP_CODE="$(curl -k -s -o /dev/null -w "%{http_code}" -u "${FORGEJO_USER}:${FORGEJO_PASS}" \
  "${FORGEJO_URL}/api/v1/repos/${FORGEJO_USER}/${REPO_NAME}" --resolve "${FORGEJO_RESOLVE}")"

if [ "${HTTP_CODE}" = "404" ]; then
  echo "  Creating repository '${REPO_NAME}' via Forgejo API..."
  curl -k -s -X POST -u "${FORGEJO_USER}:${FORGEJO_PASS}" \
    "${FORGEJO_URL}/api/v1/user/repos" --resolve "${FORGEJO_RESOLVE}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${REPO_NAME}\", \"private\": false, \"default_branch\": \"main\"}" >/dev/null
  echo "  [OK] Repository created."
else
  echo "  [OK] Repository already exists in Forgejo (HTTP ${HTTP_CODE})."
fi

echo "==> 2. Pushing current main branch to in-cluster Forgejo..."
kubectl -n git-system port-forward svc/forgejo-http 13000:3000 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 2

git remote remove forgejo 2>/dev/null || true
git remote add forgejo "http://${FORGEJO_USER}:${FORGEJO_PASS}@127.0.0.1:13000/${FORGEJO_USER}/${REPO_NAME}.git"
git push -u forgejo main --force

echo "==> 3. Repository synchronized to in-cluster Forgejo successfully."
echo "==> Actions workflow (.forgejo/workflows/validate-gitops.yaml) dispatched to Forgejo runner!"
