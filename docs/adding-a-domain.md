# Adding a Domain to Yggdrasil

This guide walks through onboarding a new domain (using `example.com` as a placeholder) into Yggdrasil's authoritative **CoreDNS** server (`dns-system`) and **`docker-mailserver`** (`mail-system`) with full security hardening:

- **DNSSEC** (`ECDSAP256SHA256` on-the-fly signing + Registrar `DS` record)
- **SPF** (Strict `-all` for root, HELO host, and non-sending subdomains)
- **DKIM** (2048-bit RSA / Ed25519 signing via Rspamd in `docker-mailserver`)
- **DMARC** (Strict alignment `adkim=s; aspf=s` with `p=reject; sp=reject`)
- **MTA-STS & SMTP TLS-RPT** (Enforced TLS for inbound mail + failure reporting)
- **DANE / TLSA** (DNSSEC-backed TLS certificate pinning on port `25`)
- **CAA** (Restricting certificate issuance to authorized CAs)
- **DNS Server Hardening** (`RFC 8482` `ANY` blocking, `minimal` responses, and `acl`-restricted recursion)

---

## Step 1: Generate a DNSSEC Signing Keypair

Run the included helper script from the repository root to generate an `ECDSAP256SHA256` (Algorithm 13) Combined Signing Key (CSK) and calculate the **Registrar `DS` Record**:

```bash
./scripts/generate-dnssec-key.sh example.com ./.dnssec-keys
```

This outputs:
1. `.dnssec-keys/Kexample.com.+013+<keytag>.key` (Public `DNSKEY`)
2. `.dnssec-keys/Kexample.com.+013+<keytag>.private` (Private signing key)
3. `.dnssec-keys/ds-record.txt` (The `DS` record to configure at your domain registrar)

### Add the Keypair to `apps/base/dns/dnssec-secret.yaml`

Add both files (`Kexample.com.+013+<keytag>.key` and `.private`) under `stringData` in `apps/base/dns/dnssec-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: coredns-dnssec-keys
  namespace: dns-system
type: Opaque
stringData:
  Kexample.com.+013+12345.key: |
    example.com. IN DNSKEY 257 3 13 <BASE64_PUBLIC_KEY>
  Kexample.com.+013+12345.private: |
    Private-key-format: v1.3
    Algorithm: 13 (ECDSAP256SHA256)
    PrivateKey: <BASE64_PRIVATE_KEY>
```

> **Production Security Note:** Never commit unencrypted production private keys to a public Git repository. Encrypt `dnssec-secret.yaml` using **Mozilla SOPS** (configured on the Flux `Kustomization` via `spec.decryption`) or **Bitnami SealedSecrets** before pushing.

---

## Step 2: Configure Mailboxes & Generate DKIM Keys in `docker-mailserver`

### 1. Add Mailboxes and Aliases (`apps/base/mail/helmrelease.yaml`)

Generate a SHA-512 password hash without exposing plaintext passwords in your shell history:

```bash
kubectl -n mail-system exec -it deploy/docker-mailserver -- setup email add postmaster@example.com
```

Or generate the hash locally to place into `apps/base/mail/helmrelease.yaml` under `values.configMap`:

```yaml
    configMap:
      postfix-accounts.cf: |
        postmaster@example.com|{SHA512-CRYPT}$6$...
      postfix-virtual.cf: |
        admin@example.com postmaster@example.com
        security@example.com postmaster@example.com
```

### 2. Generate the DKIM Keypair for `example.com`

Once the `docker-mailserver` pod is running, generate the DKIM keypair via Rspamd:

```bash
kubectl -n mail-system exec -it deploy/docker-mailserver -- setup config dkim domain example.com selector mail
```

Print the generated public key record:

```bash
kubectl -n mail-system exec -it deploy/docker-mailserver -- cat /tmp/docker-mailserver/rspamd/dkim/example.com-mail.txt
```

Copy the `v=DKIM1; k=rsa; p=...` value for Step 3.

---

## Step 3: Add the Zone & Server Block to CoreDNS

Open `apps/base/dns/helmrelease.yaml` and add:

### 1. Server Block under `values.servers`

```yaml
      - zones:
          - zone: example.com.
        port: 53
        plugins:
          - name: errors
          - name: log
          - name: any
          - name: minimal
          - name: reload
            parameters: 10s
          - name: dnssec
            parameters: example.com.
            configBlock: |-
              key file /etc/coredns/keys/Kexample.com.+013+12345
          - name: file
            parameters: /etc/coredns/example.com.db example.com.
```

### 2. Zone File under `values.zoneFiles`

Add `example.com.db` (replacing `<PUBLIC_IP>` with your cluster's ingress IP, or `127.0.0.1` in Kind, and incrementing the SOA serial `YYYYMMDDNN` on every change):

```yaml
      - filename: example.com.db
        domain: example.com
        contents: |
          $ORIGIN example.com.
          $TTL 3600
          @       IN  SOA ns1.example.com. hostmaster.example.com. (
                          2026111001 ; Serial (YYYYMMDDNN)
                          3600       ; Refresh (1h)
                          600        ; Retry (10m)
                          604800     ; Expire (1w)
                          300 )      ; Minimum TTL (5m)

          ; 1. Authoritative Nameservers & Anti-Spoofing
          @                   IN  NS      ns1.example.com.
          ns1                 IN  A       <PUBLIC_IP>
          ns1                 IN  TXT     "v=spf1 -all"

          ; 2. CAA (Restrict Certificate Issuance to Let's Encrypt)
          @                   IN  CAA     0 issue "letsencrypt.org"
          @                   IN  CAA     0 issuewild ";"
          @                   IN  CAA     0 iodef "mailto:security@example.com"

          ; 3. Web Hosting & MTA-STS Policy Endpoints
          @                   IN  A       <PUBLIC_IP>
          www                 IN  CNAME   @
          webmail             IN  CNAME   @
          mta-sts             IN  CNAME   @

          ; 4. Mail Server Routing
          mail                IN  A       <PUBLIC_IP>
          @                   IN  MX      10 mail.example.com.

          ; 5. SPF (Strict Hard-Fail for Root & HELO Host)
          @                   IN  TXT     "v=spf1 mx a:mail.example.com -all"
          mail                IN  TXT     "v=spf1 a -all"

          ; 6. DKIM Public Key
          mail._domainkey     IN  TXT     ( "v=DKIM1; k=rsa; s=email; "
                                            "p=<YOUR_DKIM_PUBLIC_KEY_BASE64>" )

          ; 7. DMARC (Strict Alignment + Quarantine/Reject Policy)
          _dmarc              IN  TXT     "v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s; pct=100; fo=1; rua=mailto:postmaster@example.com; ruf=mailto:postmaster@example.com"

          ; 8. MTA-STS & SMTP TLS Reporting
          _mta-sts            IN  TXT     "v=STSv1; id=2026111001"
          _smtp._tls          IN  TXT     "v=TLSRPTv1; rua=mailto:postmaster@example.com"

          ; 9. DANE / TLSA (SHA-256 SPKI Hash of mail.example.com TLS Certificate)
          _25._tcp.mail       IN  TLSA    3 1 1 <SHA256_SPKI_HEX_DIGEST>

          ; 10. Client Autodiscovery SRV (Enforce Encrypted Ports 587/993)
          _submission._tcp    IN  SRV     0 1 587 mail.example.com.
          _imaps._tcp         IN  SRV     0 1 993 mail.example.com.
          _imap._tcp          IN  SRV     0 0 0 .
          _pop3._tcp          IN  SRV     0 0 0 .
          _pop3s._tcp         IN  SRV     0 0 0 .
```

---

## Step 4: Verify DNS & Security Controls Locally (Kind)

Once Flux reconciles the changes (or after running `flux reconcile helmrelease coredns -n dns-system`), test against CoreDNS on port `5353` (Kind host port mapping):

```bash
# 1. Verify DNSSEC signing (RRSIG + DNSKEY records returned)
dig @127.0.0.1 -p 5353 example.com A +dnssec +multiline

# 2. Verify SPF, DKIM, DMARC, MTA-STS, and TLS-RPT TXT records
dig @127.0.0.1 -p 5353 example.com TXT +short
dig @127.0.0.1 -p 5353 mail._domainkey.example.com TXT +short
dig @127.0.0.1 -p 5353 _dmarc.example.com TXT +short
dig @127.0.0.1 -p 5353 _mta-sts.example.com TXT +short
dig @127.0.0.1 -p 5353 _smtp._tls.example.com TXT +short

# 3. Verify CAA & DANE TLSA records
dig @127.0.0.1 -p 5353 example.com CAA +short
dig @127.0.0.1 -p 5353 _25._tcp.mail.example.com TLSA +short

# 4. Verify RFC 8482 ANY query protection (returns HINFO "ANY obsoleted")
dig @127.0.0.1 -p 5353 example.com ANY +noall +answer
```
