#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

FORGEJO_NS="git-system"
FORGEJO_SVC="forgejo-http.${FORGEJO_NS}.svc.cluster.local:3000"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-yggdrasil-admin}"
FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-admin@yggdrasil.local}"
FORGEJO_ADMIN_PASS="${FORGEJO_ADMIN_PASS:-ChangeMe123!}"
FORGEJO_REPO="${FORGEJO_REPO:-yggdrasil}"

echo "==> Waiting for Forgejo deployment in '${FORGEJO_NS}' to become Ready..."
kubectl -n "${FORGEJO_NS}" rollout status deployment/forgejo --timeout=300s

FORGEJO_POD="$(kubectl -n "${FORGEJO_NS}" get pods -l app.kubernetes.io/name=forgejo -o jsonpath='{.items[0].metadata.name}')"

echo "==> Ensuring bootstrap admin user '${FORGEJO_ADMIN_USER}' exists in Forgejo..."
kubectl -n "${FORGEJO_NS}" exec "${FORGEJO_POD}" -c forgejo -- \
  forgejo admin user create \
    --username "${FORGEJO_ADMIN_USER}" \
    --password "${FORGEJO_ADMIN_PASS}" \
    --email "${FORGEJO_ADMIN_EMAIL}" \
    --admin \
    --must-change-password=false 2>/dev/null || true

echo "==> Opening local port-forward to Forgejo API..."
kubectl -n "${FORGEJO_NS}" port-forward svc/forgejo-http 13000:3000 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 3

echo "==> Creating '${FORGEJO_REPO}' repository in Forgejo (if not already present)..."
curl -sS -X POST "http://127.0.0.1:13000/api/v1/user/repos" \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${FORGEJO_REPO}\", \"private\": false, \"default_branch\": \"main\"}" >/dev/null || true

echo "==> Pushing local repository to in-cluster Forgejo..."
git remote remove cluster 2>/dev/null || true
git remote add cluster "http://${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASS}@127.0.0.1:13000/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO}.git"
git push -u cluster main --force
git remote set-url cluster "http://127.0.0.1:13000/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO}.git"

echo "==> Pivoting Flux GitRepository 'flux-system' to in-cluster Forgejo (${FORGEJO_SVC})..."
flux create secret git flux-forgejo-auth \
  --url="http://${FORGEJO_SVC}/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO}.git" \
  --username="${FORGEJO_ADMIN_USER}" \
  --password="${FORGEJO_ADMIN_PASS}" \
  --namespace=flux-system \
  --export | kubectl apply -f -

kubectl -n flux-system patch gitrepository flux-system --type=merge -p "{
  \"spec\": {
    \"url\": \"http://${FORGEJO_SVC}/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO}.git\",
    \"secretRef\": {
      \"name\": \"flux-forgejo-auth\"
    }
  }
}"

echo "==> Reconciling Flux against in-cluster Forgejo..."
flux reconcile source git flux-system
flux get sources git -A
