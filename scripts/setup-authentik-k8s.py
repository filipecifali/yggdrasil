#!/usr/bin/env python3
"""
setup-authentik-k8s.py
Configures Authentik groups, OIDC provider, scope mapping, and application
for Kubernetes API access with zero PII.
"""

from authentik.core.models import Application, Group
from authentik.crypto.models import CertificateKeyPair
from authentik.flows.models import Flow, FlowDesignation
from authentik.providers.oauth2.models import (
    OAuth2Provider,
    RedirectURI,
    RedirectURIMatchingMode,
    RedirectURIType,
    ScopeMapping,
)

print("==> 1. Configuring Authentik Groups for Kubernetes RBAC...")
GROUPS = [
    ("cluster-admins", "Cluster Administrators with full access"),
    ("platform-ops", "Platform Operators managing infrastructure and core services"),
    ("auditors", "Security Auditors with read-only view access across the cluster"),
    ("dev-web", "Application Developers for web-system workloads"),
    ("dev-git", "Application Developers for git-system workloads"),
    ("dev-chat", "Application Developers for chat-system workloads"),
    ("dev-mail", "Application Developers for mail-system workloads"),
]

for name, desc in GROUPS:
    grp, created = Group.objects.get_or_create(
        name=name,
        defaults={"attributes": {"description": desc}}
    )
    status = "Created" if created else "Exists"
    print(f"  [{status}] Group: {name}")

print("\n==> 2. Configuring Scope Mapping for 'groups' claim...")
GROUPS_EXPRESSION = """
return {
    "groups": [group.name for group in request.user.ak_groups.all()]
}
"""

groups_mapping, created = ScopeMapping.objects.get_or_create(
    name="Kubernetes Groups Mapping",
    defaults={
        "scope_name": "groups",
        "description": "Maps user groups into standard OIDC 'groups' claim for Kubernetes RBAC",
        "expression": GROUPS_EXPRESSION.strip()
    }
)
if not created:
    groups_mapping.expression = GROUPS_EXPRESSION.strip()
    groups_mapping.save()
print(f"  [OK] ScopeMapping: {groups_mapping.name} (scope: {groups_mapping.scope_name})")

# Get standard scopes: openid, email, profile
standard_scopes = list(ScopeMapping.objects.filter(
    scope_name__in=["openid", "email", "profile"]
))
all_mappings = standard_scopes + [groups_mapping]

print("\n==> 3. Configuring OAuth2/OIDC Provider for Kubernetes API...")
auth_flow = Flow.objects.filter(designation=FlowDesignation.AUTHORIZATION).first()
inv_flow = Flow.objects.filter(designation=FlowDesignation.INVALIDATION).first()

redirects = [
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.REGEX,
        url=r"^http://localhost(:[0-9]+)?/",
        redirect_uri_type=RedirectURIType.AUTHORIZATION,
    ),
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url="http://localhost:8000",
        redirect_uri_type=RedirectURIType.AUTHORIZATION,
    ),
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url="http://localhost:18000",
        redirect_uri_type=RedirectURIType.AUTHORIZATION,
    ),
]

signing_cert = CertificateKeyPair.objects.filter(name="authentik Self-signed Certificate").first()
if not signing_cert:
    signing_cert = CertificateKeyPair.objects.first()

provider, created = OAuth2Provider.objects.get_or_create(
    name="kubernetes-k8s-oidc",
    defaults={
        "client_id": "kubernetes",
        "client_type": "public",
        "authorization_flow": auth_flow,
        "invalidation_flow": inv_flow,
        "signing_key": signing_cert,
    }
)
provider.redirect_uris = redirects
provider.client_id = "kubernetes"
provider.client_type = "public"
provider.signing_key = signing_cert
if auth_flow:
    provider.authorization_flow = auth_flow
if inv_flow:
    provider.invalidation_flow = inv_flow
provider.save()

provider.property_mappings.set(all_mappings)
provider.save()
print(f"  [OK] OAuth2Provider: {provider.name} (client_id: {provider.client_id})")

print("\n==> 4. Configuring Authentik Application for Kubernetes...")
app, created = Application.objects.get_or_create(
    slug="k8s",
    defaults={
        "name": "Kubernetes API",
        "provider": provider,
    }
)
if not created:
    app.name = "Kubernetes API"
    app.provider = provider
    app.save()

print(f"  [OK] Application: {app.name} (slug: {app.slug})")
print("\n==> OIDC Issuer URL: https://auth.yggdrasil.local/application/o/k8s/")
print("==> Setup completed successfully.")
