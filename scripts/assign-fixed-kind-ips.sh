#!/usr/bin/env bash
# ==============================================================================
# assign-fixed-kind-ips.sh
# Assigns static, deterministic IP addresses to ALL Kind containers across
# yggdrasil (9 nodes + LB) and jotunheim (2 nodes) to permanently eliminate
# IP address squatting, Docker DHCP drift, and control-plane restarts.
# ==============================================================================
set -euo pipefail

KIND_NETWORK="kind"

# Deterministic IP Map for the entire Kind bridge (172.18.0.0/16)
# Yggdrasil Control Plane & LB: .2, .4, .5, .6
# Yggdrasil Workers: .11 to .16
# Jotunheim Control Plane & Worker: .21, .22
declare -A STATIC_NODE_IPS=(
  ["yggdrasil-external-load-balancer"]="172.18.0.2"
  ["yggdrasil-control-plane3"]="172.18.0.4"
  ["yggdrasil-control-plane2"]="172.18.0.5"
  ["yggdrasil-control-plane"]="172.18.0.6"
  ["yggdrasil-worker"]="172.18.0.11"
  ["yggdrasil-worker2"]="172.18.0.12"
  ["yggdrasil-worker3"]="172.18.0.13"
  ["yggdrasil-worker4"]="172.18.0.14"
  ["yggdrasil-worker5"]="172.18.0.15"
  ["yggdrasil-worker6"]="172.18.0.16"
  ["jotunheim-control-plane"]="172.18.0.21"
  ["jotunheim-worker"]="172.18.0.22"
)

echo "==> 1. Ensuring all Kind containers have restart=always..."
for CNAME in "${!STATIC_NODE_IPS[@]}"; do
  if docker inspect "${CNAME}" >/dev/null 2>&1; then
    docker update --restart=always "${CNAME}" >/dev/null
  fi
done

echo "==> 2. Disconnecting all nodes from '${KIND_NETWORK}' to clear dynamic IP pool..."
for CNAME in "${!STATIC_NODE_IPS[@]}"; do
  if docker inspect "${CNAME}" >/dev/null 2>&1; then
    docker network disconnect -f "${KIND_NETWORK}" "${CNAME}" 2>/dev/null || true
  fi
done

echo "==> 3. Reconnecting every container with its permanent fixed IP..."
for CNAME in "${!STATIC_NODE_IPS[@]}"; do
  FIXED_IP="${STATIC_NODE_IPS[${CNAME}]}"
  if docker inspect "${CNAME}" >/dev/null 2>&1; then
    echo "  -> Assigning ${FIXED_IP} to ${CNAME}..."
    docker network connect --ip "${FIXED_IP}" "${KIND_NETWORK}" "${CNAME}"
    docker start "${CNAME}" >/dev/null
  fi
done

echo "==> 4. Verifying container running status and IP assignments..."
sleep 3
for CNAME in "${!STATIC_NODE_IPS[@]}"; do
  if docker inspect "${CNAME}" >/dev/null 2>&1; then
    ASSIGNED_IP="$(docker inspect "${CNAME}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
    IS_RUNNING="$(docker inspect "${CNAME}" --format '{{.State.Running}}')"
    echo "  [OK] ${CNAME}: IP=${ASSIGNED_IP} Running=${IS_RUNNING}"
  fi
done

echo "==> Fixed IP assignment complete!"
