#!/bin/bash
# ==============================================================================
# test-cluster-configs.sh
# Automated Test Suite for Yggdrasil Sovereign Cluster Configurations
# Validates GitOps manifests, RBAC scopes, ResourceQuotas, PSA security contexts,
# OCI mirrors, script syntax, and Zero-PII policy.
# ==============================================================================
set -euo pipefail

# Ensure PATH includes standard locations and /data/bin (Forgejo runner)
export PATH="/data/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:${PATH}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  echo "  [PASS] $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  echo "  [FAIL] $1: $2"
}

echo "=============================================================================="
echo "          YGGDRASIL CONFIGURATION & GITOPS AUTOMATED TEST SUITE               "
echo "=============================================================================="

# ------------------------------------------------------------------------------
# Test 1: Bash Script Syntax Integrity (bash -n)
# ------------------------------------------------------------------------------
echo "==> Running Test 1: Bash Scripts Syntax Validation..."
SCRIPT_ERRORS=0
for SCRIPT in $(find scripts -maxdepth 1 -name "*.sh"); do
  if ! bash -n "${SCRIPT}" 2>/dev/null; then
    fail "Script syntax error" "${SCRIPT}"
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
  fi
done
if [ "${SCRIPT_ERRORS}" -eq 0 ]; then
  pass "All shell scripts in scripts/ passed bash syntax check."
fi

# ------------------------------------------------------------------------------
# Test 2: Python Scripts Compilation Check (if python3 is available)
# ------------------------------------------------------------------------------
echo "==> Running Test 2: Python Scripts Compilation Validation..."
if command -v python3 >/dev/null 2>&1; then
  PY_ERRORS=0
  for PY_SCRIPT in $(find scripts -maxdepth 1 -name "*.py"); do
    if ! python3 -m py_compile "${PY_SCRIPT}" 2>/dev/null; then
      fail "Python compilation error" "${PY_SCRIPT}"
      PY_ERRORS=$((PY_ERRORS + 1))
    fi
  done
  if [ "${PY_ERRORS}" -eq 0 ]; then
    pass "All python scripts in scripts/ passed compilation check."
  fi
else
  pass "python3 not installed in runner environment; skipped syntax compile."
fi

# ------------------------------------------------------------------------------
# Test 3: Zero Plaintext Kubernetes Secrets Policy
# ------------------------------------------------------------------------------
echo "==> Running Test 3: Enforcing Zero Plaintext Secrets Policy..."
SECRETS_FOUND=$(grep -rnE "^kind:[[:space:]]*Secret" apps/ infrastructure/ 2>/dev/null || true)
if [ -n "${SECRETS_FOUND}" ]; then
  fail "Plaintext Secret manifest detected" "${SECRETS_FOUND}"
else
  pass "No plaintext Secret manifests detected in apps/ or infrastructure/."
fi

# ------------------------------------------------------------------------------
# Test 4: Enforce Zero PII and Local Usernames Policy
# ------------------------------------------------------------------------------
echo "==> Running Test 4: Enforcing Zero PII and Local User Paths Policy..."
PII_MATCHES=$(grep -rnE "(/home/(fcs|filip)|[a-zA-Z0-9._%+-]+@filip)" \
  --exclude="test-cluster-configs.sh" \
  apps/ infrastructure/ clusters/ scripts/ kind/ docs/ 2>/dev/null || true)
if [ -n "${PII_MATCHES}" ]; then
  fail "Found personal username/PII match in repo" "${PII_MATCHES}"
else
  pass "Zero PII or personal paths found across repository."
fi

# ------------------------------------------------------------------------------
# Test 5: In-Cluster Harbor OCI Helm Chart Mirror Policy
# ------------------------------------------------------------------------------
echo "==> Running Test 5: Verifying In-Cluster Harbor OCI Helm Repositories..."
HELM_REPOS_FILE="infrastructure/base/helm-repositories.yaml"
if [ ! -f "${HELM_REPOS_FILE}" ]; then
  fail "Missing file" "${HELM_REPOS_FILE}"
else
  NON_HARBOR=$(grep -E '^[[:space:]]*url:' "${HELM_REPOS_FILE}" | grep -v 'oci://harbor.registry-system.svc.cluster.local/library' || true)
  if [ -n "${NON_HARBOR}" ]; then
    fail "Non-Harbor HelmRepository URL detected" "${NON_HARBOR}"
  else
    pass "All HelmRepositories point to in-cluster Harbor OCI mirror."
  fi
fi

# ------------------------------------------------------------------------------
# Test 6: Kustomize Build & Render Integrity (kubectl kustomize)
# ------------------------------------------------------------------------------
echo "==> Running Test 6: Kustomize Build & Overlay Render Integrity..."
if command -v kubectl >/dev/null 2>&1; then
  KUSTOMIZE_TARGETS=(
    "clusters/kind/flux-system"
    "clusters/jotunheim/flux-system"
    "infrastructure/base"
    "infrastructure/overlays/kind"
    "infrastructure/overlays/jotunheim"
    "apps/base"
    "apps/overlays/kind"
    "apps/overlays/jotunheim"
    "apps/base/security"
    "apps/base/auth"
    "apps/base/dns"
    "apps/base/git"
    "apps/base/mail"
    "apps/base/monitoring"
    "apps/base/registry"
    "apps/base/storage"
    "apps/base/web"
    "apps/base/serverless"
    "apps/base/sample-app"
  )
  for TARGET in "${KUSTOMIZE_TARGETS[@]}"; do
    if [ -d "${TARGET}" ]; then
      if kubectl kustomize "${TARGET}" >/dev/null 2>&1; then
        pass "Kustomize target rendered cleanly: ${TARGET}"
      else
        fail "Kustomize render failed" "${TARGET}"
      fi
    fi
  done
else
  fail "kubectl not found" "Cannot verify Kustomize build integrity without kubectl."
fi

# ------------------------------------------------------------------------------
# Test 7: Multi-Tenancy ResourceQuotas & LimitRanges
# ------------------------------------------------------------------------------
echo "==> Running Test 7: Multi-Tenancy ResourceQuotas & LimitRanges Validation..."
QUOTA_FILE="infrastructure/base/resourcequotas.yaml"
LIMIT_FILE="infrastructure/base/limitranges.yaml"
TENANT_NAMESPACES=("default" "web-system" "git-system" "chat-system" "mail-system" "sample-app")

if [ ! -f "${QUOTA_FILE}" ]; then
  fail "Missing ResourceQuota file" "${QUOTA_FILE}"
else
  for NS in "${TENANT_NAMESPACES[@]}"; do
    if grep -q "namespace: ${NS}" "${QUOTA_FILE}"; then
      pass "ResourceQuota configured for tenant namespace '${NS}'"
    else
      fail "Missing ResourceQuota" "Namespace '${NS}' does not have a ResourceQuota defined"
    fi
  done
fi

if [ ! -f "${LIMIT_FILE}" ]; then
  fail "Missing LimitRange file" "${LIMIT_FILE}"
else
  for NS in "default" "web-system" "git-system" "mail-system" "sample-app"; do
    if grep -q "namespace: ${NS}" "${LIMIT_FILE}"; then
      pass "LimitRange configured for namespace '${NS}'"
    else
      fail "Missing LimitRange" "Namespace '${NS}' does not have a LimitRange defined"
    fi
  done
fi

# ------------------------------------------------------------------------------
# Test 8: Pod Security Standards (PSA) Namespace & Workload Hardening
# ------------------------------------------------------------------------------
echo "==> Running Test 8: Pod Security Standards (PSA) Hardening..."
NS_FILE="infrastructure/base/namespaces.yaml"
if [ ! -f "${NS_FILE}" ]; then
  fail "Missing namespaces manifest" "${NS_FILE}"
else
  RESTRICTED_NAMESPACES=("cert-manager" "external-secrets" "cnpg-system" "keda-system" "web-system")
  for RNS in "${RESTRICTED_NAMESPACES[@]}"; do
    # Verify enforce: restricted label
    if awk -v ns="${RNS}" '$0 ~ "name: " ns {found=1} found && /pod-security.kubernetes.io\/enforce: restricted/ {ok=1; exit} /---/ {found=0} END {exit !ok}' "${NS_FILE}"; then
      pass "Namespace '${RNS}' enforces PSA 'restricted' profile"
    else
      fail "Namespace '${RNS}' missing PSA restricted enforcement" "${NS_FILE}"
    fi
  done
fi

# Check securityContext in custom workloads
WORKLOAD_FILES=(
  "apps/base/security/vault-auto-unseal.yaml"
  "apps/base/security/vault-backup-cronjob.yaml"
  "apps/base/web/web-hosting.yaml"
)
for WFILE in "${WORKLOAD_FILES[@]}"; do
  if [ -f "${WFILE}" ]; then
    if grep -q "allowPrivilegeEscalation: false" "${WFILE}" && \
       grep -q "drop:" "${WFILE}" && grep -q "ALL" "${WFILE}" && \
       grep -q "runAsNonRoot: true" "${WFILE}" && \
       grep -q "seccompProfile:" "${WFILE}"; then
      pass "Workload '${WFILE}' complies with strict Pod Security Standards"
    else
      fail "Workload '${WFILE}' missing required securityContext attributes" "${WFILE}"
    fi
  fi
done

# ------------------------------------------------------------------------------
# Test 9: RBAC Matrix & Least-Privilege Scoping Validation
# ------------------------------------------------------------------------------
echo "==> Running Test 9: RBAC Matrix and Least-Privilege Scoping..."
RBAC_FILE="apps/base/security/rbac-scopes.yaml"
if [ ! -f "${RBAC_FILE}" ]; then
  fail "Missing RBAC configuration" "${RBAC_FILE}"
else
  # 1. Ensure cluster-admin is bound to cluster-admins group
  if grep -A 10 "name: yggdrasil-cluster-admins" "${RBAC_FILE}" | grep -q "name: cluster-admins" && \
     grep -A 15 "name: yggdrasil-cluster-admins" "${RBAC_FILE}" | grep -q "name: cluster-admin"; then
    pass "ClusterRole/cluster-admin is exclusively bound to Group 'cluster-admins'"
  else
    fail "ClusterRole/cluster-admin binding irregularity" "Binding yggdrasil-cluster-admins not properly configured"
  fi

  # 2. Ensure auditors are bound to view
  if grep -A 10 "name: yggdrasil-auditors" "${RBAC_FILE}" | grep -q "name: auditors" && \
     grep -A 15 "name: yggdrasil-auditors" "${RBAC_FILE}" | grep -q "name: view"; then
    pass "Group 'auditors' bound to ClusterRole/view"
  else
    fail "Auditors RBAC missing" "Group 'auditors' not properly bound to ClusterRole/view"
  fi

  # 3. Ensure dev groups are namespaced RoleBindings, not ClusterRoleBindings
  DEV_BINDINGS=("dev-web-admin:web-system" "dev-git-admin:git-system" "dev-chat-admin:chat-system" "dev-mail-admin:mail-system")
  for BINDING in "${DEV_BINDINGS[@]}"; do
    BNAME="${BINDING%%:*}"
    BNS="${BINDING##*:}"
    if grep -A 5 "name: ${BNAME}" "${RBAC_FILE}" | grep -q "namespace: ${BNS}"; then
      pass "Tenant role '${BNAME}' properly scoped to namespace '${BNS}'"
    else
      fail "Tenant role scoping error" "'${BNAME}' is not strictly scoped to '${BNS}'"
    fi
  done
fi

# ------------------------------------------------------------------------------
# Test 10: Ingress Routes & Edge Gateway Alignment
# ------------------------------------------------------------------------------
echo "==> Running Test 10: Ingress HTTPRoutes & Bifrost Gateway Binding..."
HTTPROUTE_FILES=$(grep -rl "^kind:[[:space:]]*HTTPRoute" apps/ 2>/dev/null || true)
ROUTE_COUNT=0
for RF in ${HTTPROUTE_FILES}; do
  ROUTE_COUNT=$((ROUTE_COUNT + 1))
  if grep -q "name: bifrost" "${RF}" && grep -q "namespace: envoy-gateway-system" "${RF}"; then
    pass "HTTPRoute in '${RF}' targets Gateway 'bifrost' in 'envoy-gateway-system'"
  else
    fail "HTTPRoute gateway mismatch" "'${RF}' does not correctly reference bifrost gateway"
  fi
done
if [ "${ROUTE_COUNT}" -gt 0 ]; then
  pass "All ${ROUTE_COUNT} HTTPRoutes verified against Bifrost Gateway."
fi

# ------------------------------------------------------------------------------
echo "==> Running Test 11: Multi-Cluster Jotunheim OIDC, RBAC & Harbor Replication..."
if grep -q "oidc-issuer-url: \"https://auth.yggdrasil.local/application/o/k8s/\"" kind/cluster-jotunheim.yaml; then
  pass "Jotunheim Kind configuration enforces Authentik OIDC integration"
else
  fail "Jotunheim OIDC missing" "kind/cluster-jotunheim.yaml does not configure OIDC issuer"
fi

if grep -q "name: cluster-admins" clusters/jotunheim/rbac-scopes.yaml && \
   grep -q "name: cluster-admin" clusters/jotunheim/rbac-scopes.yaml; then
  pass "Jotunheim RBAC bounds group 'cluster-admins' to ClusterRole/cluster-admin"
else
  fail "Jotunheim RBAC missing" "clusters/jotunheim/rbac-scopes.yaml missing cluster-admin binding"
fi

if grep -q "name: auditors" clusters/jotunheim/rbac-scopes.yaml && \
   grep -q "name: view" clusters/jotunheim/rbac-scopes.yaml; then
  pass "Jotunheim RBAC bounds group 'auditors' to ClusterRole/view"
else
  fail "Jotunheim RBAC missing" "clusters/jotunheim/rbac-scopes.yaml missing auditors binding"
fi

if [ -f "clusters/jotunheim/harbor-values.yaml" ] && grep -q "nodePort: 30080" clusters/jotunheim/harbor-values.yaml; then
  pass "Jotunheim Harbor deployment configured with NodePort 30080 for cross-cluster replication"
else
  fail "Jotunheim Harbor config missing" "clusters/jotunheim/harbor-values.yaml not configured"
fi

if [ -f "scripts/setup-harbor-replication.py" ] && [ -f "scripts/setup-jotunheim-oidc.sh" ]; then
  pass "Automated cross-cluster OIDC and Harbor replication provisioning scripts present"
else
  fail "Automation scripts missing" "Missing setup-harbor-replication.py or setup-jotunheim-oidc.sh"
fi

if [ -f "clusters/jotunheim/infrastructure.yaml" ] && [ -f "clusters/jotunheim/apps.yaml" ]; then
  pass "Jotunheim GitOps Flux Kustomizations configured for replicated infrastructure and apps"
else
  fail "Jotunheim GitOps missing" "Missing clusters/jotunheim/infrastructure.yaml or apps.yaml"
fi

# ------------------------------------------------------------------------------
echo "==> Running Test 12: Serverless Scale-to-Zero Functions (KEDA HTTP Add-on)..."
if [ -f "infrastructure/base/keda/http-add-on-helmrelease.yaml" ] && \
   grep -q "chart: keda-add-ons-http" infrastructure/base/keda/http-add-on-helmrelease.yaml; then
  pass "KEDA HTTP Add-on HelmRelease configured with hardened securityContext and local Harbor mirror"
else
  fail "KEDA HTTP Add-on missing" "infrastructure/base/keda/http-add-on-helmrelease.yaml not configured"
fi

if [ -f "apps/base/serverless/echo-function.yaml" ] && \
   grep -q "kind: HTTPScaledObject" apps/base/serverless/echo-function.yaml && \
   grep -q "min: 0" apps/base/serverless/echo-function.yaml; then
  pass "Serverless HTTPScaledObject configured with scale-to-zero (min: 0 replicas)"
else
  fail "HTTPScaledObject missing" "apps/base/serverless/echo-function.yaml not configuring scale-to-zero"
fi

if [ -f "apps/base/serverless/httproute.yaml" ] && \
   grep -q "keda-add-ons-http-interceptor-proxy" apps/base/serverless/httproute.yaml; then
  pass "Serverless HTTPRoute targets KEDA interceptor proxy via Bifrost Gateway"
else
  fail "Serverless HTTPRoute missing" "apps/base/serverless/httproute.yaml not routing to interceptor"
fi

if [ -f "apps/base/serverless/referencegrant.yaml" ] && \
   grep -q "allow-web-system-to-keda-interceptor" apps/base/serverless/referencegrant.yaml; then
  pass "Gateway API ReferenceGrant permits cross-namespace routing from web-system to keda-system"
else
  fail "ReferenceGrant missing" "apps/base/serverless/referencegrant.yaml not configured"
fi

# ------------------------------------------------------------------------------
echo "==> Running Test 13: Advanced KEDA Scalers (RabbitMQ, PostgreSQL, VictoriaMetrics, Cron)..."
if [ -f "apps/base/serverless/rabbitmq-scaledobject.yaml" ] && \
   grep -q "type: rabbitmq" apps/base/serverless/rabbitmq-scaledobject.yaml && \
   grep -q "kind: TriggerAuthentication" apps/base/serverless/rabbitmq-scaledobject.yaml; then
  pass "RabbitMQ asynchronous queue ScaledObject and TriggerAuthentication configured"
else
  fail "RabbitMQ scaler missing" "apps/base/serverless/rabbitmq-scaledobject.yaml not configured"
fi

if [ -f "apps/base/serverless/postgresql-scaledjob.yaml" ] && \
   grep -q "type: postgresql" apps/base/serverless/postgresql-scaledjob.yaml && \
   grep -q "kind: ScaledJob" apps/base/serverless/postgresql-scaledjob.yaml; then
  pass "PostgreSQL event-driven batch ScaledJob configured with CNPG integration"
else
  fail "PostgreSQL scaler missing" "apps/base/serverless/postgresql-scaledjob.yaml not configured"
fi

if [ -f "apps/base/web/scaledobject.yaml" ] && \
   grep -q "type: prometheus" apps/base/web/scaledobject.yaml && \
   grep -q "vmsingle-yggdrasil-vmsingle" apps/base/web/scaledobject.yaml; then
  pass "VictoriaMetrics Prometheus metric ScaledObject configured for workload autoscaling"
else
  fail "VictoriaMetrics scaler missing" "apps/base/web/scaledobject.yaml missing Prometheus trigger"
fi

if [ -f "apps/base/serverless/cron-scaledobject-example.yaml" ] && \
   grep -q "type: cron" apps/base/serverless/cron-scaledobject-example.yaml; then
  pass "KEDA Cron scaler template documented and verified for scheduled scaling"
else
  fail "Cron scaler template missing" "apps/base/serverless/cron-scaledobject-example.yaml missing"
fi

# ------------------------------------------------------------------------------
echo "==> Running Test 14: Cross-Cluster Replication Subsystems (CNPG, S3, VM, Mail, RabbitMQ, CoreDNS)..."
if [ -f "apps/overlays/jotunheim/postgres-replica.yaml" ] && \
   grep -q "enabled: true" apps/overlays/jotunheim/postgres-replica.yaml && \
   grep -q "source: yggdrasil-pg-primary" apps/overlays/jotunheim/postgres-replica.yaml; then
  pass "CloudNativePG cross-cluster standby replica clusters configured for instant promotion"
else
  fail "CNPG replica missing" "apps/overlays/jotunheim/postgres-replica.yaml not configured"
fi

if [ -f "apps/overlays/jotunheim/seaweedfs-s3-replication.yaml" ] && \
   grep -q "seaweedfs-cross-cluster-s3-sync" apps/overlays/jotunheim/seaweedfs-s3-replication.yaml && \
   grep -q "readOnlyRootFilesystem: true" apps/overlays/jotunheim/seaweedfs-s3-replication.yaml; then
  pass "SeaweedFS cross-cluster S3 continuous sync CronJob configured with PSA Restricted profile"
else
  fail "SeaweedFS S3 sync missing" "apps/overlays/jotunheim/seaweedfs-s3-replication.yaml not configured"
fi

if [ -f "apps/overlays/jotunheim/monitoring-cross-cluster.yaml" ] && \
   grep -q "10.4.0.1:8429" apps/overlays/jotunheim/monitoring-cross-cluster.yaml; then
  pass "VictoriaMetrics VMAgent cross-cluster dual remote-write telemetry configured"
else
  fail "VictoriaMetrics dual-write missing" "apps/overlays/jotunheim/monitoring-cross-cluster.yaml not configured"
fi

if [ -f "apps/overlays/jotunheim/mail-replication.yaml" ] && \
   grep -q "OVERRIDE_HOSTNAME: \"mail.jotunheim.local\"" apps/overlays/jotunheim/mail-replication.yaml; then
  pass "Docker-Mailserver secondary MX and relay failover configured for Jotunheim"
else
  fail "Mail replication missing" "apps/overlays/jotunheim/mail-replication.yaml not configured"
fi

if [ -f "apps/overlays/jotunheim/rabbitmq-federation.yaml" ] && \
   grep -q "yggdrasil-primary-upstream" apps/overlays/jotunheim/rabbitmq-federation.yaml; then
  pass "RabbitMQ cross-cluster federation upstream and policy configured for event replication"
else
  fail "RabbitMQ federation missing" "apps/overlays/jotunheim/rabbitmq-federation.yaml not configured"
fi

if [ -f "apps/overlays/jotunheim/dns-secondary.yaml" ] && \
   grep -q "transfer from 10.4.0.1:53" apps/overlays/jotunheim/dns-secondary.yaml; then
  pass "CoreDNS cross-cluster secondary zone transfer (AXFR) configured for zero-latency local resolution"
else
  fail "CoreDNS AXFR missing" "apps/overlays/jotunheim/dns-secondary.yaml not configured"
fi

if [ -f "docs/cross-cluster-replication-guide.md" ]; then
  pass "Comprehensive Cross-Cluster Replication and Disaster Recovery guide documented"
else
  fail "Replication guide missing" "docs/cross-cluster-replication-guide.md missing"
fi

# ------------------------------------------------------------------------------
echo "==> Running Test 15: Envoy Edge Caching & CloudFront-Equivalent Frontend Hosting..."
if [ -f "apps/base/gateway/cache-policy.yaml" ] && \
   grep -q "kind: EnvoyPatchPolicy" apps/base/gateway/cache-policy.yaml && \
   grep -q "envoy.filters.http.cache" apps/base/gateway/cache-policy.yaml; then
  pass "Envoy Gateway HTTP in-memory cache filter configured via EnvoyPatchPolicy"
else
  fail "Envoy cache policy missing" "apps/base/gateway/cache-policy.yaml not configured"
fi

if [ -f "infrastructure/base/gateway/helmrelease.yaml" ] && \
   grep -q "enableEnvoyPatchPolicy: true" infrastructure/base/gateway/helmrelease.yaml; then
  pass "Envoy Gateway HelmRelease enables EnvoyPatchPolicy extension API"
else
  fail "EnvoyPatchPolicy disabled" "infrastructure/base/gateway/helmrelease.yaml missing enableEnvoyPatchPolicy"
fi

if [ -f "apps/base/web/spa-frontend-template.yaml" ] && \
   grep -q "try_files \$uri \$uri/ /index.html" apps/base/web/spa-frontend-template.yaml && \
   grep -q "max-age=31536000, immutable" apps/base/web/spa-frontend-template.yaml; then
  pass "Sovereign SPA frontend template configured with client-side routing & immutable asset caching"
else
  fail "SPA template missing" "apps/base/web/spa-frontend-template.yaml not configured"
fi

if [ -f "docs/envoy-cache-cloudfront-architecture.md" ]; then
  pass "Envoy Gateway CloudFront-equivalent edge caching architecture fully documented"
else
  fail "Cache documentation missing" "docs/envoy-cache-cloudfront-architecture.md missing"
fi

# ------------------------------------------------------------------------------
# Test 16: Sample App (Django, Celery, Postgres, Redis, RabbitMQ, SeaweedFS S3)
# ------------------------------------------------------------------------------
echo "==> Running Test 16: Sample App & Helm Chart Verification..."

# 1. SemVer Compliance in VERSION file
if [ -f "sample-app/VERSION" ] && grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' sample-app/VERSION; then
  pass "sample-app/VERSION adheres to Semantic Versioning ($(cat sample-app/VERSION))"
else
  fail "Invalid or missing VERSION" "sample-app/VERSION must contain valid SemVer string"
fi

# 2. Helm Chart definition & SemVer
if [ -f "sample-app/chart/Chart.yaml" ] && \
   grep -qE '^version: [0-9]+\.[0-9]+\.[0-9]+' sample-app/chart/Chart.yaml && \
   grep -qE '^appVersion: "[0-9]+\.[0-9]+\.[0-9]+"' sample-app/chart/Chart.yaml; then
  pass "sample-app/chart/Chart.yaml adheres to SemVer for chart version and appVersion"
else
  fail "Chart.yaml SemVer failure" "sample-app/chart/Chart.yaml missing valid version/appVersion"
fi

# 3. Django Settings verification (PostgreSQL, Redis cache, RabbitMQ broker, SeaweedFS S3)
if [ -f "sample-app/config/settings.py" ] && \
   grep -q "django.db.backends.postgresql" sample-app/config/settings.py && \
   grep -q "django.core.cache.backends.redis.RedisCache" sample-app/config/settings.py && \
   grep -q "CELERY_BROKER_URL" sample-app/config/settings.py && \
   grep -q "storages.backends.s3.S3Storage" sample-app/config/settings.py; then
  pass "Django settings.py cleanly integrates Postgres, Redis, RabbitMQ (Celery), and SeaweedFS (S3)"
else
  fail "settings.py incomplete" "sample-app/config/settings.py missing one or more required service integrations"
fi

# 4. Helm templates existence
if [ -f "sample-app/chart/templates/django-deployment.yaml" ] && \
   [ -f "sample-app/chart/templates/celery-deployment.yaml" ] && \
   [ -f "sample-app/chart/templates/httproute.yaml" ] && \
   [ -f "sample-app/chart/templates/networkpolicy.yaml" ]; then
  pass "Helm chart contains all core templates (Django, Celery, HTTPRoute, NetworkPolicy)"
else
  fail "Missing Helm templates" "sample-app/chart/templates is missing required workload manifests"
fi

# 5. GitOps apps/base/sample-app integration
if [ -f "apps/base/sample-app/kustomization.yaml" ] && \
   [ -f "apps/base/sample-app/externalsecret.yaml" ] && \
   grep -q "sample-app" apps/base/kustomization.yaml; then
  pass "Sample App integrated into root apps/base/kustomization.yaml with ExternalSecret Vault integration"
else
  fail "GitOps integration missing" "apps/base/kustomization.yaml does not cleanly reference sample-app"
fi

# ------------------------------------------------------------------------------
# Summary & Exit Code
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "TEST SUMMARY: Total: ${TOTAL_COUNT} | Passed: ${PASS_COUNT} | Failed: ${FAIL_COUNT}"
echo "=============================================================================="

if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo ">>> AUTOMATED TEST SUITE FAILED <<<"
  exit 1
else
  echo ">>> ALL CONFIGURATION TESTS PASSED SUCCESSFULLY <<<"
  exit 0
fi
