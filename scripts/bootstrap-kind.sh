#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CLUSTER_NAME="yggdrasil"
GITHUB_OWNER="${GITHUB_OWNER:-$(gh api user -q .login)}"
GITHUB_REPO="${GITHUB_REPO:-yggdrasil}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
PIVOT_TO_FORGEJO="${PIVOT_TO_FORGEJO:-false}"

echo "==> Checking Docker daemon..."
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running. Start it with: sudo service docker start"
  exit 1
fi

echo "==> Checking WSL inotify limits (multi-node Kind requires max_user_instances >= 8192)..."
CURRENT_INOTIFY="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 128)"
if [ "${CURRENT_INOTIFY}" -lt 8192 ]; then
  echo "WARNING: fs.inotify.max_user_instances is ${CURRENT_INOTIFY} (< 8192)."
  echo "Run: sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576"
fi

if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "==> Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --config kind/cluster-config.yaml
else
  echo "==> Kind cluster '${CLUSTER_NAME}' already exists."
fi

echo "==> Running Flux pre-flight checks..."
flux check --pre

echo "==> Bootstrapping Flux v2 from ${GITHUB_OWNER}/${GITHUB_REPO}..."
export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
flux bootstrap github \
  --owner="${GITHUB_OWNER}" \
  --repository="${GITHUB_REPO}" \
  --branch="${GITHUB_BRANCH}" \
  --path=./clusters/kind \
  --personal \
  --private=false

echo "==> Pulling generated flux-system manifests..."
git pull --rebase

if [ "${PIVOT_TO_FORGEJO}" = "true" ]; then
  echo "==> Waiting for Flux Kustomizations to deploy Forgejo before pivoting..."
  flux reconcile kustomization infrastructure --with-source
  flux reconcile kustomization apps --with-source
  ./scripts/pivot-to-forgejo.sh
fi

echo "==> Current Flux & Node-Pool status:"
kubectl get nodes -L yggdrasil.io/node-pool
flux get all
