#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-yggdrasil}"
HARBOR_NS="registry-system"
HARBOR_HOST="registry.yggdrasil.local"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-$(kubectl -n "${HARBOR_NS}" get secret harbor-admin-credentials -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)}"

# Upstream -> Harbor Local Mirror image map
IMAGES=(
  "docker.io/envoyproxy/envoy:distroless-v1.33.0|${HARBOR_HOST}/library/envoy:distroless-v1.33.0"
  "registry.k8s.io/coredns/coredns:v1.12.0|${HARBOR_HOST}/library/coredns:1.12.0"
  "docker.io/hashicorp/vault:1.19.0|${HARBOR_HOST}/library/vault:1.19.0"
  "ghcr.io/cloudnative-pg/postgresql:18.1|${HARBOR_HOST}/library/postgresql:18.1"
  "docker.io/chrislusf/seaweedfs:4.00|${HARBOR_HOST}/library/seaweedfs:4.00"
  "docker.io/victoriametrics/victoria-metrics:v1.115.0|${HARBOR_HOST}/library/victoria-metrics:v1.115.0"
  "docker.io/victoriametrics/vmagent:v1.115.0|${HARBOR_HOST}/library/vmagent:v1.115.0"
  "code.forgejo.org/forgejo/forgejo:11.0.1|${HARBOR_HOST}/library/forgejo:11.0.1"
  "code.forgejo.org/forgejo/runner:6|${HARBOR_HOST}/library/forgejo-runner:6"
  "ghcr.io/docker-mailserver/docker-mailserver:15.0.0|${HARBOR_HOST}/library/docker-mailserver:15.0.0"
  "docker.io/roundcube/roundcubemail:1.6.9-apache|${HARBOR_HOST}/library/roundcubemail:1.6.9-apache"
  "docker.io/nginxinc/nginx-unprivileged:1.27-alpine|${HARBOR_HOST}/library/nginx-unprivileged:1.27-alpine"
)

echo "==> Waiting for Harbor deployment in '${HARBOR_NS}' to become Ready..."
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-core --timeout=300s
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-registry --timeout=300s
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor --timeout=300s

HARBOR_CLUSTER_IP="$(kubectl -n "${HARBOR_NS}" get svc harbor -o jsonpath='{.spec.clusterIP}')"

echo "==> Configuring containerd on all Kind nodes to resolve '${HARBOR_HOST}' to Harbor ClusterIP (${HARBOR_CLUSTER_IP})..."
for NODE in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${NODE}" mkdir -p "/etc/containerd/certs.d/${HARBOR_HOST}"
  docker exec -i "${NODE}" tee "/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" >/dev/null << TOML
server = "http://${HARBOR_CLUSTER_IP}"

[host."http://${HARBOR_CLUSTER_IP}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
  [host."http://${HARBOR_CLUSTER_IP}".header]
    Host = ["${HARBOR_HOST}"]
TOML
done

echo "==> Opening local port-forward to Harbor (${HARBOR_NS}/svc/harbor)..."
kubectl -n "${HARBOR_NS}" port-forward svc/harbor 18080:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 3

echo "==> Logging into Harbor via local port-forward..."
echo "${HARBOR_PASS}" | docker login 127.0.0.1:18080 -u "${HARBOR_USER}" --password-stdin

for ENTRY in "${IMAGES[@]}"; do
  SRC="${ENTRY%%|*}"
  DST="${ENTRY##*|}"
  LOCAL_PUSH_TAG="${DST/${HARBOR_HOST}/127.0.0.1:18080}"

  echo "==> Mirroring ${SRC} -> ${DST} ..."
  docker pull "${SRC}"
  docker tag "${SRC}" "${LOCAL_PUSH_TAG}"
  docker push "${LOCAL_PUSH_TAG}"
  docker rmi "${LOCAL_PUSH_TAG}" >/dev/null 2>&1 || true
done

echo "==> All application images mirrored to Harbor (${HARBOR_HOST}/library/*)!"
