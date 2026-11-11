#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

CLUSTER_NAME="${CLUSTER_NAME:-yggdrasil}"
HARBOR_NS="registry-system"
HARBOR_HOST="registry.yggdrasil.local"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-$(kubectl -n "${HARBOR_NS}" get secret harbor-admin-credentials -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)}"

# Ensure crane is installed in ~/.local/bin for fast, daemonless OCI/Docker V2 image mirroring
if ! command -v crane >/dev/null 2>&1; then
  echo "==> Installing crane to ~/.local/bin/crane..."
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v0.20.3/go-containerregistry_Linux_x86_64.tar.gz" \
    | tar -xz -C "${HOME}/.local/bin" crane
  chmod +x "${HOME}/.local/bin/crane"
fi

# Upstream -> Harbor Local Mirror image map
IMAGES=(
  "docker.io/envoyproxy/envoy:distroless-v1.33.0|${HARBOR_HOST}/library/envoy:distroless-v1.40.2"
  "registry.k8s.io/coredns/coredns:v1.12.0|${HARBOR_HOST}/library/coredns:1.12.0"
  "docker.io/hashicorp/vault:1.19.0|${HARBOR_HOST}/library/vault:1.19.0"
  "ghcr.io/cloudnative-pg/postgresql:18.1|${HARBOR_HOST}/library/postgresql:18.1"
  "docker.io/chrislusf/seaweedfs:4.53|${HARBOR_HOST}/library/seaweedfs:4.53"
  "docker.io/victoriametrics/victoria-metrics:v1.115.0|${HARBOR_HOST}/library/victoria-metrics:v1.115.0"
  "docker.io/victoriametrics/vmagent:v1.115.0|${HARBOR_HOST}/library/vmagent:v1.115.0"
  "code.forgejo.org/forgejo/forgejo:11.0.1-rootless|${HARBOR_HOST}/library/forgejo:11.0.1-rootless"
  "code.forgejo.org/forgejo/runner:6|${HARBOR_HOST}/library/forgejo-runner:6"
  "ghcr.io/docker-mailserver/docker-mailserver:15.0.0|${HARBOR_HOST}/library/docker-mailserver:15.0.0"
  "docker.io/roundcube/roundcubemail:1.6.9-apache|${HARBOR_HOST}/library/roundcubemail:1.6.9-apache"
  "docker.io/nginxinc/nginx-unprivileged:1.27-alpine|${HARBOR_HOST}/library/nginx-unprivileged:1.27-alpine"
  "docker.io/squat/kilo:0.7.0|${HARBOR_HOST}/library/kilo:0.7.0"
  "ghcr.io/goauthentik/server:2026.8.5|${HARBOR_HOST}/library/authentik-server:2026.8.5"
  "ghcr.io/goauthentik/ldap:2026.8.5|${HARBOR_HOST}/library/authentik-ldap:2026.8.5"
  "ghcr.io/zulip/zulip-server:12.4-0|${HARBOR_HOST}/library/zulip-server:12.4-0"
  "docker.io/zulip/zulip-postgresql:14|${HARBOR_HOST}/library/zulip-postgresql:14"
  "docker.io/bitnamilegacy/rabbitmq:4.1.3|${HARBOR_HOST}/library/rabbitmq:4.1.3"
  "docker.io/bitnamilegacy/memcached:latest|${HARBOR_HOST}/library/memcached:latest"
  "docker.io/bitnamilegacy/redis:latest|${HARBOR_HOST}/library/redis:latest"
)

echo "==> Waiting for Harbor deployment in '${HARBOR_NS}' to become Ready..."
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-core --timeout=300s
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-registry --timeout=300s
kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-nginx --timeout=300s

# Ensure harbor-core EXT_ENDPOINT uses http:// so its /v2/ Bearer token realm works over HTTP ClusterIP & port-forward
CURRENT_EXT="$(kubectl -n "${HARBOR_NS}" get cm harbor-core -o jsonpath='{.data.EXT_ENDPOINT}')"
if [[ "${CURRENT_EXT}" == https://* ]]; then
  echo "==> Updating harbor-core EXT_ENDPOINT to http://${HARBOR_HOST} for internal HTTP pulls..."
  kubectl -n "${HARBOR_NS}" patch cm harbor-core --type merge -p "{\"data\":{\"EXT_ENDPOINT\":\"http://${HARBOR_HOST}\"}}"
  kubectl -n "${HARBOR_NS}" rollout restart deployment/harbor-core deployment/harbor-registry
  kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-core --timeout=300s
  kubectl -n "${HARBOR_NS}" rollout status deployment/harbor-registry --timeout=300s
fi

HARBOR_CLUSTER_IP="$(kubectl -n "${HARBOR_NS}" get svc harbor -o jsonpath='{.spec.clusterIP}')"

echo "==> Configuring containerd on all Kind nodes to resolve '${HARBOR_HOST}' to Harbor ClusterIP (${HARBOR_CLUSTER_IP})..."
for NODE in $(kind get nodes --name "${CLUSTER_NAME}"); do
  if [[ "${NODE}" == *load-balancer* ]]; then
    continue
  fi
  docker exec "${NODE}" mkdir -p "/etc/containerd/certs.d/${HARBOR_HOST}"
  docker exec -i "${NODE}" tee "/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" >/dev/null << TOML
server = "http://${HARBOR_CLUSTER_IP}"

[host."http://${HARBOR_CLUSTER_IP}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
TOML

  # Remove any /etc/hosts entry for HARBOR_HOST so containerd never attempts TCP :443 against the HTTP-only ClusterIP
  docker exec "${NODE}" bash -c "grep -v '${HARBOR_HOST}' /etc/hosts > /tmp/hosts && cat /tmp/hosts > /etc/hosts" || true

  # Ensure containerd config.toml has config_path = "/etc/containerd/certs.d" enabled
  if ! docker exec "${NODE}" grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml; then
    echo "  -> Enabling certs.d in ${NODE}:/etc/containerd/config.toml and restarting containerd..."
    docker exec -i "${NODE}" tee -a /etc/containerd/config.toml >/dev/null << 'CTOML'

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
CTOML
    docker exec "${NODE}" systemctl restart containerd
  fi
done

echo "==> Opening local port-forward to Harbor (${HARBOR_NS}/svc/harbor)..."
kubectl -n "${HARBOR_NS}" port-forward svc/harbor 18080:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
sleep 3

echo "==> Logging into Harbor via crane..."
crane auth login 127.0.0.1:18080 -u "${HARBOR_USER}" -p "${HARBOR_PASS}" --insecure

for ENTRY in "${IMAGES[@]}"; do
  SRC="${ENTRY%%|*}"
  DST="${ENTRY##*|}"
  LOCAL_PUSH_TAG="${DST/${HARBOR_HOST}/127.0.0.1:18080}"

  echo "==> Mirroring ${SRC} -> ${DST} ..."
  crane copy --insecure --platform linux/amd64 "${SRC}" "${LOCAL_PUSH_TAG}"
done

echo "==> Restarting any pods waiting in ImagePullBackOff / ErrImagePull..."
for POD_LINE in $(kubectl get pods -A --no-headers | awk '$4 ~ /ImagePullBackOff|ErrImagePull|Init:ImagePullBackOff|Init:ErrImagePull/ {print $1 "/" $2}'); do
  NS="${POD_LINE%%/*}"
  POD="${POD_LINE##*/}"
  kubectl -n "${NS}" delete pod "${POD}" --wait=false || true
done

echo "==> All application images mirrored to Harbor (${HARBOR_HOST}/library/*)!"
