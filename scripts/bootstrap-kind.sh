#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CLUSTER_NAME="yggdrasil"
GITHUB_OWNER="${GITHUB_OWNER:-$(gh api user -q .login)}"
GITHUB_REPO="${GITHUB_REPO:-yggdrasil}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

echo "==> Checking Docker daemon..."
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running. Start it with: sudo service docker start"
  exit 1
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

echo "==> Flux bootstrap complete! Pulling generated flux-system manifests..."
git pull --rebase

echo "==> Current Flux & Namespace status:"
flux get all
kubectl get ns
