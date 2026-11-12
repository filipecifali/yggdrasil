#!/usr/bin/env bash
set -euo pipefail

HARBOR_NS="registry-system"
HARBOR_HOST="registry.yggdrasil.local"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-$(kubectl -n "${HARBOR_NS}" get secret harbor-admin-credentials -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)}"

echo "==> Configuring Harbor project 'library' to private (public=false)..."
kubectl -n "${HARBOR_NS}" exec deploy/harbor-core -- curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" \
  -X PUT "http://127.0.0.1:8080/api/v2.0/projects/library" \
  -H "Content-Type: application/json" \
  -d '{"metadata": {"public": "false"}}'

echo "==> Disabling user self-registration in Harbor..."
kubectl -n "${HARBOR_NS}" exec deploy/harbor-core -- curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" \
  -X PUT "http://127.0.0.1:8080/api/v2.0/configurations" \
  -H "Content-Type: application/json" \
  -d '{"self_registration": false}'

echo "==> Verifying project 'library' status..."
kubectl -n "${HARBOR_NS}" exec deploy/harbor-core -- curl -s -u "${HARBOR_USER}:${HARBOR_PASS}" \
  "http://127.0.0.1:8080/api/v2.0/projects/library" | grep -o '"public":"[^"]*"'

HARBOR_CLUSTER_IP="$(kubectl -n "${HARBOR_NS}" get svc harbor -o jsonpath='{.spec.clusterIP}')"
AUTH_B64="$(echo -n "${HARBOR_USER}:${HARBOR_PASS}" | base64)"

echo "==> Configuring containerd on all Kind nodes with registry authentication..."
for NODE in $(kind get nodes --name yggdrasil); do
  if [[ "${NODE}" == *load-balancer* ]]; then
    continue
  fi
  echo "  -> Configuring ${NODE}..."
  docker exec "${NODE}" mkdir -p "/etc/containerd/certs.d/${HARBOR_HOST}"
  docker exec -i "${NODE}" tee "/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" >/dev/null << TOML
server = "http://${HARBOR_CLUSTER_IP}"

[host."http://${HARBOR_CLUSTER_IP}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
  [host."http://${HARBOR_CLUSTER_IP}".header]
    Authorization = "Basic ${AUTH_B64}"
TOML

  # Ensure config.toml has CRI registry credentials so kubelet image pulls authenticate
  if ! docker exec "${NODE}" grep -q "registry.configs.\"${HARBOR_HOST}\".auth" /etc/containerd/config.toml 2>/dev/null; then
    docker exec -i "${NODE}" tee -a /etc/containerd/config.toml >/dev/null << CTOML

[plugins."io.containerd.grpc.v1.cri".registry.configs."${HARBOR_HOST}".auth]
  username = "${HARBOR_USER}"
  password = "${HARBOR_PASS}"
CTOML
    docker exec "${NODE}" systemctl restart containerd
  fi
done

echo "==> Harbor project 'library' is now PRIVATE with node credentials configured!"
