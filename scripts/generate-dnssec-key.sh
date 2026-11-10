#!/usr/bin/env bash
set -euo pipefail

ZONE="${1:-yggdrasil.local}"
ZONE="${ZONE%.}."
ZONE_NAME="${ZONE%.}"
OUT_DIR="${2:-./.dnssec-keys}"

mkdir -p "${OUT_DIR}"

python3 - "${ZONE}" "${ZONE_NAME}" "${OUT_DIR}" << 'PYEOF'
import base64
import hashlib
import struct
import sys
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

zone_fqdn = sys.argv[1]
zone_name = sys.argv[2]
out_dir = sys.argv[3]

# Generate ECDSA P-256 keypair (DNSSEC Algorithm 13: ECDSAP256SHA256)
private_key = ec.generate_private_key(ec.SECP256R1())
numbers = private_key.private_numbers()
pub_numbers = numbers.public_numbers

# Raw 64-byte public key (X || Y, 32 bytes each) and 32-byte private key
x_bytes = pub_numbers.x.to_bytes(32, byteorder="big")
y_bytes = pub_numbers.y.to_bytes(32, byteorder="big")
pub_raw = x_bytes + y_bytes
priv_raw = numbers.private_value.to_bytes(32, byteorder="big")

pub_b64 = base64.b64encode(pub_raw).decode("ascii")
priv_b64 = base64.b64encode(priv_raw).decode("ascii")

# DNSKEY RDATA: flags=257 (KSK/CSK), protocol=3, algorithm=13
flags = 257
protocol = 3
algorithm = 13
rdata = struct.pack("!HBB", flags, protocol, algorithm) + pub_raw

# RFC 4034 Appendix B Key Tag calculation
ac = 0
for i, b in enumerate(rdata):
    ac += (b << 8) if (i & 1) == 0 else b
ac += (ac >> 16) & 0xFFFF
key_tag = ac & 0xFFFF

# Wire-format owner name for DS digest (SHA-256, digest type 2)
wire_name = b"".join(
    bytes([len(label)]) + label.encode("ascii").lower()
    for label in zone_fqdn.rstrip(".").split(".")
) + b"\x00"
ds_sha256 = hashlib.sha256(wire_name + rdata).hexdigest().upper()

base_name = f"K{zone_name}.+013+{key_tag:05d}"
key_path = f"{out_dir}/{base_name}.key"
priv_path = f"{out_dir}/{base_name}.private"

with open(key_path, "w") as f:
    f.write(f"{zone_fqdn} IN DNSKEY {flags} {protocol} {algorithm} {pub_b64}\n")

with open(priv_path, "w") as f:
    f.write(
        "Private-key-format: v1.3\n"
        "Algorithm: 13 (ECDSAP256SHA256)\n"
        f"PrivateKey: {priv_b64}\n"
    )

with open(f"{out_dir}/keyname.txt", "w") as f:
    f.write(base_name)

with open(f"{out_dir}/ds-record.txt", "w") as f:
    f.write(f"{zone_fqdn} IN DS {key_tag} {algorithm} 2 {ds_sha256}\n")

print(f"Generated DNSSEC CSK: {base_name}")
print(f"Registrar DS Record:  {zone_fqdn} IN DS {key_tag} {algorithm} 2 {ds_sha256}")
PYEOF
