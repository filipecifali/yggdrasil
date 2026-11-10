# Kilo WireGuard Mesh & Multi-Cluster Peering Guide

This document details the architecture, deployment, configuration, and verification of **Kilo** (`squat/kilo`) as an encrypted WireGuard mesh and multi-cluster VPN connecting **Yggdrasil** (*Niflheim*) with external Kubernetes clusters (demonstrated with **Jotunheim**).

---

## 1. Architecture & Overview

[Kilo](https://kilo.squat.ai) creates an encrypted, full-mesh or point-to-point WireGuard network across distributed Kubernetes nodes, non-Kubernetes peers, and external clusters.

```
+-------------------------------------------------------------+
|                     WSL 2 / Docker Network                  |
|                        172.18.0.0/16                        |
+------------------------------+------------------------------+
                               |
       +-----------------------+-----------------------+
       |                                               |
       v                                               v
+-----------------------------+ +-----------------------------+
|     Cluster: Yggdrasil      | |     Cluster: Jotunheim      |
|  Location: yggdrasil        | |  Location: jotunheim        |
|  Pod CIDR: 10.244.0.0/16    | |  Pod CIDR: 10.245.0.0/16    |
|  Service:  10.96.0.0/12     | |  Service:  10.112.0.0/12    |
|  Kilo WG:  10.4.0.0/16      | |  Kilo WG:  10.5.0.0/16      |
|  Endpoint: 172.18.0.5:51820 | |  Endpoint: 172.18.0.8:51820 |
+--------------+--------------+ +--------------+--------------+
               |                               |
               |     WireGuard Encrypted       |
               +<=============================>+
                   Interface: kilo0 (MTU 1420)
```

### Key Design Tenets
1. **Co-existence with Kindnet (`--cni=false`, `--local=false`):**
   - Kind uses `kindnetd` as its default local CNI.
   - By running Kilo with `--cni=false` and `--local=false`, Kilo **does not** manage intra-node or intra-cluster pod networking. Kindnet manages local routing over `eth0`.
   - Kilo manages exclusively the `kilo0` WireGuard device and programs routes for external peer locations and remote clusters.
2. **Native Kernel WireGuard:**
   - WSL 2 kernel (`6.18.x-microsoft-standard-WSL2`) has in-tree WireGuard module support. Kilo uses native Linux kernel WireGuard interfaces without userspace fallback (`wireguard-go`).
3. **Location-Based Mesh Topology (`--topology-label`):**
   - Nodes are labeled with `yggdrasil.io/location=<cluster-name>`.
   - Nodes within the same location communicate over their local bridge; traffic destined for another location or external peer is routed and encapsulated through `kilo0`.
4. **Harbor-Mirrored OCI Image:**
   - Kilo image is mirrored to Harbor: `registry.yggdrasil.local/library/kilo:0.7.0` (upstream: `docker.io/squat/kilo:0.7.0`).

---

## 2. IP & Subnet Scheme

To guarantee clean, conflict-free routing across clusters, all CIDRs must be mutually disjoint:

| Resource | Yggdrasil | Jotunheim | Notes |
| :--- | :--- | :--- | :--- |
| **Cluster Realm** | *Niflheim* (`vpn-system`) | `vpn-system` | Privileged PSS namespace |
| **Node Location Label** | `yggdrasil.io/location=yggdrasil` | `yggdrasil.io/location=jotunheim` | Used by Kilo topology engine |
| **Underlay Network** | `172.18.0.0/16` (`kind`) | `172.18.0.0/16` (`kind`) | Docker bridge |
| **Pod CIDR** | `10.244.0.0/16` | `10.245.0.0/16` | Non-overlapping |
| **Service CIDR** | `10.96.0.0/12` | `10.112.0.0/12` | Non-overlapping |
| **Kilo Subnet** | `10.4.0.0/16` | `10.5.0.0/16` | WireGuard internal IP pool |
| **WireGuard Port** | `51820/UDP` | `51820/UDP` | Bound per node on `hostNetwork` |

---

## 3. Manifest Structure

### Yggdrasil (`infrastructure/base/kilo/`)
```
infrastructure/base/kilo/
├── crds.yaml             # CustomResourceDefinition: peers.kilo.squat.ai
├── daemonset.yaml        # ServiceAccount, RBAC ClusterRole, and DaemonSet
├── kustomization.yaml    # Kustomize resources list
└── peer-jotunheim.yaml   # Peer resource pointing to Jotunheim cluster
```

### Kilo DaemonSet Arguments
```yaml
containers:
  - name: kilo
    image: registry.yggdrasil.local/library/kilo:0.7.0
    args:
      - --hostname=$(NODE_NAME)
      - --cni=false
      - --local=false
      - --interface=kilo0
      - --subnet=10.4.0.0/16
      - --service-cidr=10.96.0.0/12
      - --port=51820
      - --clean-up=true
      - --topology-label=yggdrasil.io/location
      - --iptables-forward-rules=true
```

---

## 4. Multi-Cluster Peering via `Peer` CRD

When connecting two clusters, each cluster deploys a `Peer` resource specifying the remote cluster leader's WireGuard public key, endpoint IP/port, and allowed IP ranges.

### Peer on Yggdrasil (`peer-jotunheim.yaml`)
```yaml
apiVersion: kilo.squat.ai/v1alpha1
kind: Peer
metadata:
  name: jotunheim
  labels:
    yggdrasil.io/realm: niflheim
    yggdrasil.io/tier: infrastructure
spec:
  publicKey: <jotunheim-control-plane-wireguard-public-key>
  endpoint:
    dnsOrIP:
      ip: 172.18.0.8
    port: 51820
  allowedIPs:
    - 10.245.0.0/16   # Jotunheim Pod CIDR
    - 10.112.0.0/12   # Jotunheim Service CIDR
    - 10.5.0.0/16     # Jotunheim Kilo mesh subnet
```

### Peer on Jotunheim (`peer-yggdrasil.yaml`)
```yaml
apiVersion: kilo.squat.ai/v1alpha1
kind: Peer
metadata:
  name: yggdrasil
spec:
  publicKey: <yggdrasil-control-plane-wireguard-public-key>
  endpoint:
    dnsOrIP:
      ip: 172.18.0.5
    port: 51820
  allowedIPs:
    - 10.244.0.0/16   # Yggdrasil Pod CIDR
    - 10.96.0.0/12    # Yggdrasil Service CIDR
    - 10.4.0.0/16     # Yggdrasil Kilo mesh subnet
```

---

## 5. Verification & Testing

### 1. Inspect Automatic Kernel Routes
Once the `Peer` resources are applied, Kilo automatically programs static routes for the remote subnets into the node's kernel routing table:

```bash
# On Yggdrasil node:
docker exec yggdrasil-control-plane ip route | grep kilo0
# Output:
# 10.4.0.0/16 dev kilo0 proto kernel scope link src 10.4.0.1 
# 10.5.0.0/16 dev kilo0 proto static src 172.18.0.5 
# 10.112.0.0/12 dev kilo0 proto static src 172.18.0.5 
# 10.245.0.0/16 dev kilo0 proto static src 172.18.0.5 

# On Jotunheim node:
docker exec jotunheim-control-plane ip route | grep kilo0
# Output:
# 10.4.0.0/16 dev kilo0 proto static src 172.18.0.8 
# 10.5.0.0/16 dev kilo0 proto kernel scope link src 10.5.0.1 
# 10.96.0.0/12 dev kilo0 proto static src 172.18.0.8 
# 10.244.0.0/16 dev kilo0 proto static src 172.18.0.8 
```

### 2. End-to-End Pod-to-Pod Communication
Deploy a receiver pod on Jotunheim (`10.245.0.5:8080`) and connect from a sender pod on Yggdrasil (`10.244.0.5`):

```bash
# Test TCP connection from Yggdrasil to Jotunheim Pod
kubectl --context kind-yggdrasil exec test-sender -- nc -zv -w 5 10.245.0.5 8080
# Output: 10.245.0.5 (10.245.0.5:8080) open

# Send payload across WireGuard tunnel
echo "Ping from Yggdrasil" | kubectl --context kind-yggdrasil exec -i test-sender -- nc 10.245.0.5 8080
# Response received: Hello from Jotunheim via WireGuard Kilo Mesh!
```

### 3. Cross-Cluster Service ClusterIP Routing
Kilo encapsulates and routes requests destined for the remote cluster's Kubernetes Service ClusterIP:

```bash
# Connect to Jotunheim Service ClusterIP (10.112.133.29:8080) from Yggdrasil
echo "Ping to Service" | kubectl --context kind-yggdrasil exec -i test-sender -- nc 10.112.133.29 8080
# Response: Hello from Jotunheim via WireGuard Kilo Mesh!
```

### 4. Bidirectional ICMP Ping Verification
```bash
# Ping Yggdrasil pod (10.244.0.5) from Jotunheim pod
kubectl --context kind-jotunheim exec test-receiver -- ping -c 3 10.244.0.5
# 3 packets transmitted, 3 packets received, 0% packet loss, avg rtt 0.638 ms
```
