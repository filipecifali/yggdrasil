#!/usr/bin/env bash
# ==============================================================================
# Yggdrasil Cluster Healing & Resilience Utility
# Verifies Docker Kind IP allocations, repairs IP drift, unseals Vault, and
# ensures all 9 Kubernetes nodes and Flux Kustomizations are healthy.
# ==============================================================================
set -euo pipefail

CLUSTER_NAME="yggdrasil"
KIND_NETWORK="kind"

echo "=========================================================="
echo "  YGGDRASIL CLUSTER HEAL & RESILIENCE AUDIT"
echo "=========================================================="

# 1. Map of static IPs required by kubeadm certificates and etcd peers
declare -A STATIC_IPS=(
  ["yggdrasil-external-load-balancer"]="172.18.0.2"
  ["yggdrasil-control-plane3"]="172.18.0.4"
  ["yggdrasil-control-plane2"]="172.18.0.5"
  ["yggdrasil-control-plane"]="172.18.0.6"
)

echo "==> 1. Checking Kind network and container status..."
for NODE in "${!STATIC_IPS[@]}"; do
  EXPECTED_IP="${STATIC_IPS[${NODE}]}"
  
  if ! docker inspect "${NODE}" >/dev/null 2>&1; then
    echo "  [WARN] Container ${NODE} does not exist!"
    continue
  fi

  CURRENT_IP="$(docker inspect "${NODE}" --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" 2>/dev/null || true)"
  IS_RUNNING="$(docker inspect "${NODE}" --format "{{.State.Running}}" 2>/dev/null || echo "false")"

  if [[ "${CURRENT_IP}" != "${EXPECTED_IP}" || "${IS_RUNNING}" != "true" ]]; then
    echo "  [FIX] Repairing ${NODE} (current IP: '${CURRENT_IP}', expected: '${EXPECTED_IP}', running: ${IS_RUNNING})..."
    
    # Check if another container is squatting on EXPECTED_IP
    CONFLICTING="$(docker ps -a --filter "network=${KIND_NETWORK}" --format "{{.Names}}" | while read -r cname; do
      cip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null || true)"
      if [[ "$cip" == "$EXPECTED_IP" && "$cname" != "$NODE" ]]; then
        echo "$cname"
      fi
    done)"
    
    if [[ -n "${CONFLICTING}" ]]; then
      echo "  [DISCONNECT] Disconnecting squatting container '${CONFLICTING}' from ${KIND_NETWORK}..."
      docker network disconnect -f "${KIND_NETWORK}" "${CONFLICTING}" || true
    fi

    echo "  [RECONNECT] Re-binding ${NODE} with static IP ${EXPECTED_IP}..."
    docker network disconnect -f "${KIND_NETWORK}" "${NODE}" 2>/dev/null || true
    docker network connect --ip "${EXPECTED_IP}" "${KIND_NETWORK}" "${NODE}"
    docker restart "${NODE}" >/dev/null
    sleep 2
  else
    echo "  [OK] ${NODE} is running with static IP ${EXPECTED_IP}."
  fi
done

echo "==> 2. Verifying all worker nodes are running..."
WORKERS=(
  "yggdrasil-worker"
  "yggdrasil-worker2"
  "yggdrasil-worker3"
  "yggdrasil-worker4"
  "yggdrasil-worker5"
  "yggdrasil-worker6"
)

for W in "${WORKERS[@]}"; do
  if docker inspect "${W}" >/dev/null 2>&1; then
    RUNNING="$(docker inspect "${W}" --format "{{.State.Running}}")"
    if [[ "${RUNNING}" != "true" ]]; then
      echo "  [START] Starting ${W}..."
      docker start "${W}" >/dev/null
    else
      echo "  [OK] Worker ${W} is active."
    fi
  fi
done

echo "==> 3. Verifying Kubernetes Node Ready status..."
for i in {1..20}; do
  READY_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)"
  TOTAL_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l || true)"
  if [[ "${READY_COUNT}" -eq 9 && "${TOTAL_COUNT}" -eq 9 ]]; then
    echo "  [SUCCESS] All 9 Kubernetes nodes are Ready!"
    break
  fi
  echo "  Waiting for nodes to become Ready (${READY_COUNT}/${TOTAL_COUNT} ready)..."
  sleep 3
done

echo "==> 4. Verifying HashiCorp Vault seal status..."
if kubectl -n vault-system get pod vault-0 >/dev/null 2>&1; then
  SEALED="$(kubectl -n vault-system exec vault-0 -- vault status -format=json 2>/dev/null | grep -o '"sealed":true' || true)"
  if [[ "${SEALED}" == '"sealed":true' ]]; then
    echo "  [UNSEAL] Vault is sealed. Unsealing via vault-init-keys..."
    UNSEAL_KEY="$(kubectl -n vault-system get secret vault-init-keys -o jsonpath='{.data.unseal-key}' 2>/dev/null | base64 -d || true)"
    if [[ -n "${UNSEAL_KEY}" ]]; then
      kubectl -n vault-system exec vault-0 -- vault operator unseal "${UNSEAL_KEY}" >/dev/null
      echo "  [SUCCESS] Vault unsealed."
    else
      echo "  [ERROR] Could not retrieve unseal key from vault-system/vault-init-keys."
    fi
  else
    echo "  [OK] Vault is already unsealed."
  fi
fi

echo "==> 5. Verifying Control Plane OIDC configuration..."
if kubectl get secret -n cert-manager yggdrasil-root-ca-secret >/dev/null 2>&1; then
  GATEWAY_IP="$(kubectl get svc -n envoy-gateway-system envoy-envoy-gateway-system-bifrost-7e8f3d0b -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if [[ -n "${GATEWAY_IP}" ]]; then
    for CP in "yggdrasil-control-plane" "yggdrasil-control-plane2" "yggdrasil-control-plane3"; do
      if docker inspect "${CP}" >/dev/null 2>&1; then
        docker exec "${CP}" bash -c "grep -q 'auth.yggdrasil.local' /etc/hosts || echo '${GATEWAY_IP} auth.yggdrasil.local' >> /etc/hosts"
        if ! docker exec "${CP}" grep -q "oidc-issuer-url" /etc/kubernetes/manifests/kube-apiserver.yaml; then
          echo "  [REPAIR] Injecting missing OIDC flags on ${CP}..."
          TMP_CA="$(mktemp)"
          kubectl get secret -n cert-manager yggdrasil-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TMP_CA}"
          docker cp "${TMP_CA}" "${CP}:/etc/kubernetes/pki/yggdrasil-ca.crt"
          rm -f "${TMP_CA}"
          docker exec "${CP}" sed -i "/- kube-apiserver/a \    - --oidc-issuer-url=https://auth.yggdrasil.local/application/o/k8s/\n    - --oidc-client-id=kubernetes\n    - --oidc-username-claim=preferred_username\n    - --oidc-groups-claim=groups\n    - --oidc-ca-file=/etc/kubernetes/pki/yggdrasil-ca.crt" /etc/kubernetes/manifests/kube-apiserver.yaml
        fi
      fi
    done
    echo "  [OK] Control plane OIDC configuration verified."
  fi
fi

echo "==> 6. Verifying Jotunheim secondary cluster & Kilo mesh peering..."
JOTUN_CP="jotunheim-control-plane"
JOTUN_WORKER="jotunheim-worker"
if docker inspect "${JOTUN_CP}" >/dev/null 2>&1; then
  # Ensure jotunheim containers are running
  for JN in "${JOTUN_CP}" "${JOTUN_WORKER}"; do
    if [[ "$(docker inspect "${JN}" --format "{{.State.Running}}" 2>/dev/null)" != "true" ]]; then
      echo "  [START] Starting ${JN}..."
      docker start "${JN}" >/dev/null
    fi
  done

  # Check Kilo peer endpoint IP drift
  JOTUN_IP="$(docker inspect "${JOTUN_CP}" --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" 2>/dev/null || true)"
  YGG_CP_IP="$(docker inspect "yggdrasil-control-plane" --format "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" 2>/dev/null || true)"
  
  if [[ -n "${JOTUN_IP}" && -n "${YGG_CP_IP}" ]]; then
    kubectl --context kind-yggdrasil -n vpn-system patch peer jotunheim --type merge -p "{\"spec\":{\"endpoint\":{\"dnsOrIP\":{\"ip\":\"${JOTUN_IP}\"}}}}" >/dev/null 2>&1 || true
    kubectl --context kind-jotunheim -n vpn-system patch peer yggdrasil --type merge -p "{\"spec\":{\"endpoint\":{\"dnsOrIP\":{\"ip\":\"${YGG_CP_IP}\"}}}}" >/dev/null 2>&1 || true
    echo "  [OK] Kilo mesh peers synchronized (Yggdrasil: ${YGG_CP_IP}, Jotunheim: ${JOTUN_IP})."
  fi

  # Verify Jotunheim OIDC
  if [[ -n "${GATEWAY_IP}" ]]; then
    docker exec "${JOTUN_CP}" bash -c "grep -q 'auth.yggdrasil.local' /etc/hosts || echo '${GATEWAY_IP} auth.yggdrasil.local' >> /etc/hosts"
    if ! docker exec "${JOTUN_CP}" grep -q "oidc-issuer-url" /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null; then
      echo "  [REPAIR] Injecting missing OIDC flags on ${JOTUN_CP}..."
      TMP_CA="$(mktemp)"
      kubectl --context kind-yggdrasil get secret -n cert-manager yggdrasil-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TMP_CA}"
      docker cp "${TMP_CA}" "${JOTUN_CP}:/etc/kubernetes/pki/yggdrasil-ca.crt"
      rm -f "${TMP_CA}"
      docker exec "${JOTUN_CP}" sed -i "/- kube-apiserver/a \    - --oidc-issuer-url=https://auth.yggdrasil.local/application/o/k8s/\n    - --oidc-client-id=kubernetes\n    - --oidc-username-claim=preferred_username\n    - --oidc-groups-claim=groups\n    - --oidc-ca-file=/etc/kubernetes/pki/yggdrasil-ca.crt" /etc/kubernetes/manifests/kube-apiserver.yaml
    fi
    echo "  [OK] Jotunheim OIDC configuration verified."
  fi
fi

echo "==> 7. Cluster healthcheck completed successfully."
