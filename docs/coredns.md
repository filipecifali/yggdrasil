# CoreDNS Authoritative DNS (`dns-system`)

## Purpose
Runs a dedicated, standalone authoritative **CoreDNS** server (*Mimir*) in `dns-system` (completely separate from `kube-system`'s internal `kube-dns`) to serve domain zones (`yggdrasil.local.`) with on-the-fly **DNSSEC** signing and email/web security records.

## Manifests Location
- `apps/base/dns/helmrelease.yaml` — CoreDNS `HelmRelease`, plugins, and `yggdrasil.local.db` zone file
- `apps/base/dns/dnssec-secret.yaml` — DNSSEC Combined Signing Key (`Secret/coredns-dnssec-keys`)
- `apps/overlays/kind/dns-nodeport.yaml` — Exposes port `53` TCP/UDP on Kind `NodePort 30053` (Host port `5353`)
- `scripts/generate-dnssec-key.sh` — Helper script to generate `ECDSAP256SHA256` keys and registrar `DS` records

## Important Configuration

1. **Standalone Mode (`isClusterService: false`)**
   - Prevents the Helm chart from colliding with `kube-system` cluster DNS and pins the deployment to `yggdrasil.io/node-pool: platform`.

2. **DNSSEC Key Secret Projection**
   - Kubernetes `Secret` key names cannot contain `+`, whereas CoreDNS expects BIND-style filenames (`Kyggdrasil.local.+013+05707.key` / `.private`).
   - `Secret/coredns-dnssec-keys` stores the keys under `dnssec.key` and `dnssec.private`, and `helmrelease.yaml` projects them to `/etc/coredns/keys/Kyggdrasil.local.+013+05707.*` via `extraVolumes` `items`.

3. **Server-Level Security Plugins**
   - `dnssec`: Signs responses on the fly (`RRSIG`, `DNSKEY`, `NSEC`).
   - `any`: Implements **RFC 8482** (`HINFO "ANY obsoleted"`) to block DNS amplification attacks.
   - `minimal`: Strips unnecessary additional/authority sections from responses.
   - `acl`: Restricts recursive forwarding (`.` zone) strictly to private RFC 1918 and loopback subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `127.0.0.0/8`) to prevent Open Resolver abuse.
   - `reload 10s`: Automatically hot-reloads zone files within 10 seconds when Flux updates the zone `ConfigMap`.

For step-by-step instructions on adding new domains and configuring `SPF`, `DKIM`, `DMARC`, `MTA-STS`, `DANE/TLSA`, and `CAA`, see [**`adding-a-domain.md`**](adding-a-domain.md).
