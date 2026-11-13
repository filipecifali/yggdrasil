# Multi-Provider EU Sovereign Cloud Architecture & Deployment Guide

This document outlines the operational and architectural plan for migrating and running the **Yggdrasil** (Primary Hub) and **Jotunheim** (Secondary Replicated Spoke) multi-cluster Kubernetes platform across **two independent European cloud providers** with zero US corporate ownership.

---

## 1. Executive Summary & Legal Sovereignty

To guarantee total sovereignty, data privacy, and legal immunity against foreign extraterritorial access laws (specifically the **US CLOUD Act** and FISA 702), the hosting infrastructure is diversified across two independent European Union member states:

```
+----------------------------------------------------------------------------------------------------+
|                                    EUROPEAN DATA SOVEREIGNTY                                       |
+-------------------------------------------------+--------------------------------------------------+
|            PROVIDER A: HETZNER ONLINE           |               PROVIDER B: OVHCLOUD               |
|            Federal Republic of Germany 🇩🇪       |               French Republic 🇫🇷                 |
+-------------------------------------------------+--------------------------------------------------+
| * 100% German Privately Owned (Martin Hetzner)  | * 100% French Publicly Owned (Euronext: OVH)     |
| * Jurisdiction: EU / German BDSG / GDPR         | * Jurisdiction: EU / French CNIL / GDPR          |
| * Data Centers: Falkenstein / Nuremberg, DE     | * Data Centers: Roubaix / Gravelines / Paris, FR |
| * Certifications: ISO/IEC 27001, ECO Datacenter | * Certifications: SecNumCloud (ANSSI), BSI C5    |
+-------------------------------------------------+--------------------------------------------------+
```

---

## 2. EU Sovereign Cloud Providers Directory

The following providers were audited to ensure **100% European headquarters and beneficial ownership**:

| Provider | Country / HQ | Primary Offerings | Kubernetes Options | EU Regions | Key Certifications |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Hetzner Online** | **Germany** 🇩🇪 *(Private)* | Cloud VMs, Bare Metal, vSwitch, Floating IPs | Self-Managed (Kubeadm, Talos, k3s via Hetzner CSI/CCM) | Germany (Falkenstein, Nuremberg), Finland (Helsinki) | ISO 27001, GDPR, Green Energy |
| **OVHcloud** | **France** 🇫🇷 *(Public)* | Public Cloud (OpenStack), Bare Metal, Hosted Private Cloud | Managed K8s (MKS - free control plane) or Self-Managed | France (Roubaix, Gravelines, Strasbourg), Germany, Poland | SecNumCloud (ANSSI), BSI C5, ISO 27001/27701, HDS |
| **Scaleway** | **France** 🇫🇷 *(Iliad Group)* | Cloud Instances, Elastic Metal, S3 Storage | Managed K8s (Kapsule & Kosmos multi-cloud engine) | France (Paris), Netherlands (Amsterdam), Poland (Warsaw) | ISO 27001, HDS, CISPE, GDPR |
| **IONOS Cloud** | **Germany** 🇩🇪 *(United Internet)* | Dedicated Core IaaS, Bare Metal, S3 Object Storage | Managed K8s (Compute-only billing, automated upgrades) | Germany (Frankfurt, Berlin), Spain (Logroño), UK | BSI C5, ISO 27001, Gaia-X Founding Member |
| **UpCloud** | **Finland** 🇫🇮 *(Private)* | Cloud Servers (MaxIOPS storage), SDN Private Networks | Managed K8s (UKS) or Self-Managed with 45s node boot | Finland (Helsinki), Germany, Netherlands, Poland, Spain | ISO 27001, GDPR, 100% European Ownership |
| **STACKIT** | **Germany** 🇩🇪 *(Schwarz Group)* | Sovereign Enterprise IaaS, Cloud Foundry, S3 | Managed K8s (SKE based on Gardener) | Germany (Frankfurt, Eppingen), Austria (Vienna) | BSI C5, ISO 27001, 100% German Corporate Ownership |
| **Cleura** | **Sweden** 🇸🇪 *(Cleura AB)* | OpenStack Compliant Cloud, S3 Storage | Managed K8s (Gardener / Magnum) or Native OpenStack | Sweden (Stockholm, Karlskrona), Germany (Frankfurt) | ISO 27001 / 9001, PCI-DSS Level 1, Nordic Privacy |

---

## 3. Real Workload Resource Analysis & Right-Sizing

### The Reality Check: 18 Nodes vs Actual Footprint
The local development cluster uses 9 containers (`3 CP` + `3 platform` + `3 apps`) to simulate a multi-zone datacenter topology. Replicating this 1:1 with 9 large virtual machines per provider (18 VMs total) costs **~€637/month** and wastes ~85% of allocated RAM.

The actual concurrent runtime consumption of the complete Yggdrasil platform is measured below:

| Component Category | Subsystems | Real RAM Footprint | Real CPU Load (Idle / Burst) |
| :--- | :--- | :---: | :---: |
| **Kubernetes Core & Mesh** | etcd, kube-apiserver, Kilo WireGuard, CoreDNS | ~1.5 GB | 0.3 / 1.0 vCPU |
| **Ingress & Security** | Envoy Gateway (Bifrost), Vault (Raft), Cert-Manager, External-Secrets | ~0.8 GB | 0.2 / 0.6 vCPU |
| **Storage & Databases** | CloudNative-PG (`yggdrasil-pg`, `authentik-pg`), SeaweedFS S3 | ~1.5 GB | 0.5 / 1.5 vCPU |
| **Registry & CI** | Harbor (Registry, Core, DB, Redis, Jobservice), Forgejo + Runner | ~2.2 GB | 0.4 / 2.0 vCPU |
| **Observability** | VictoriaMetrics, Fluent Bit, Grafana, VMAlert, Exporters | ~1.0 GB | 0.3 / 0.8 vCPU |
| **Collaboration & Auth** | Authentik (Server + Worker), Zulip Chat, Mailserver + Roundcube | ~4.5 GB | 1.0 / 2.5 vCPU |
| **Serverless & Web** | KEDA + HTTP Add-on, NGINX Web Hosting, Function workers | ~0.5 GB | 0.2 / 1.0 vCPU |
| **Host Overhead** | Linux Kernel, containerd, file system cache | ~2.0 GB | 0.5 vCPU |
| **TOTAL PER CLUSTER** | **Entire Active Sovereign Platform** | **~14.0 GB RAM** | **~3.4 vCPU (8.0 peak)** |

---

### Right-Sizing Options

#### Model 1: The "3-Node Converged HA" Architecture (Recommended)
Combines control-plane and worker roles onto **3 multi-role nodes per cluster** using Talos Linux, Kubeadm, or K3s. 
* Any single node in either cluster can reboot or fail without losing etcd quorum or interrupting ingress.
* **6 nodes total across both providers** (instead of 18).

| Cluster | Provider & Region | Node Type | Specs (per node) | Qty | Cost / mo (excl. VAT) |
| :--- | :--- | :--- | :--- | :---: | :---: |
| **Cluster 1: Yggdrasil** | **Hetzner** *(Falkenstein, DE)* | `CPX41` (AMD) | 8 vCPU, 16 GB RAM, 240 GB NVMe | 3 | **€80.10** |
| **Cluster 2: Jotunheim** | **OVHcloud** *(Roubaix, FR)* | `b2-15` / `b3-16` | 4–8 vCPU, 15–16 GB RAM, 100–160 GB NVMe | 3 | **€96.00** |
| **COMBINED TOTAL** | | **36 vCPUs \| 96 GB RAM \| 1.2 TB NVMe** | **6** | **~€176.10 / mo** |

*Annual run rate: **~€2,113 / year** (72% cost savings vs €7,648/year for 18 VMs).*

---

#### Model 2: The "Dual Bare-Metal Hypervisor" Architecture (Maximum Power)
Rent **1 dedicated bare-metal server per provider** and run Proxmox VE, Harvester, or raw bare-metal Kubernetes.

| Cluster | Provider & Region | Server Model | Hardware Specs | Cost / mo (excl. VAT) |
| :--- | :--- | :--- | :--- | :---: |
| **Cluster 1: Yggdrasil** | **Hetzner** *(Germany)* | `AX42` / `AX52` | **AMD Ryzen 7 7700** (8c/16t), **64 GB DDR5**, 2x 1 TB NVMe | **€46.00** |
| **Cluster 2: Jotunheim** | **OVHcloud** *(France)* | `Rise-1` / `Eco` | **Intel Xeon E-2386G** (6c/12t), **32–64 GB RAM**, 2x 512 GB NVMe | **€52.00** |
| **COMBINED TOTAL** | | **28 Cores / 56 Threads \| 128 GB RAM \| 3 TB NVMe** | **2** | **~€98.00 / mo** |

*Annual run rate: **~€1,176 / year** (85% cost savings with enterprise-grade physical NVMe disks).*

---

## 4. Fully Replicated Multi-Cluster Topology

To satisfy the requirement that **Jotunheim contains all components that Yggdrasil has**, the platform uses a **Symmetric Active-Passive / Active-Active** synchronization model:

```
+----------------------------------------------------------------------------------------------------------+
|                                        GIT REPOSITORY (GITOPS SOURCE)                                    |
|                                        Flux v2 Reconciles Both Clusters                                  |
+---------------------------------------------------+------------------------------------------------------+
                                                    |
                         +--------------------------+--------------------------+
                         |                                                     |
                         v                                                     v
+---------------------------------------------------+ +----------------------------------------------------+
|               CLUSTER 1: YGGDRASIL                | |                CLUSTER 2: JOTUNHEIM                 |
|             (Hetzner - Primary Realm)             | |             (OVHcloud - Replicated Realm)          |
+---------------------------------------------------+ +----------------------------------------------------+
| • Kube-APIServer (Authentik OIDC enabled)         | | • Kube-APIServer (Federated OIDC to Yggdrasil Auth)|
| • Envoy Gateway Bifrost (*.yggdrasil.local)       | | • Envoy Gateway Bifrost (*.jotunheim.local / fail) |
| • Primary Harbor Registry (Push Replication) ------> • Secondary Harbor Registry (Local OCI Cache)       |
| • CloudNative-PG Primary Clusters (WAL Archiving)--> • CloudNative-PG Standby Clusters (Continuous Replay)|
| • SeaweedFS S3 Primary Buckets --------------------> • SeaweedFS S3 Replicated Mirror                     |
| • Authentik IdP (Authoritative Identity Provider) | | • Authentik Proxy / Federated Read-Replica         |
| • Zulip Team Chat (Active Instance)               | | • Zulip Standby / DR Instance                      |
| • Mailserver + Roundcube (MX Primary)             | | • Mailserver Secondary MX / Standby Webmail        |
| • Forgejo Git Forge (Primary GitOps Remote) ------> • Forgejo Git Mirror / Runner Standby                |
| • VictoriaMetrics + Grafana Telemetry Hub         | | • VictoriaMetrics Regional Ingest + Cross-Scrape   |
| • KEDA + HTTP Add-on + Advanced Scalers           | | • KEDA + HTTP Add-on + Advanced Scalers            |
+---------------------------------------------------+ +----------------------------------------------------+
                         ^                                                     ^
                         |                                                     |
                         +================= KILO WIREGUARD MESH ===============+
                                    Encrypted Cross-Cluster Interconnect
```

---

## 5. Subsystem Replication Strategy Matrix

| Subsystem | Primary (Yggdrasil @ Hetzner) | Secondary (Jotunheim @ OVHcloud) | Replication Mechanism | Failover RTO / RPO |
| :--- | :--- | :--- | :--- | :--- |
| **Container & Helm OCI** | Harbor Primary (`registry.yggdrasil.local`) | Harbor Secondary (`registry-system:30080`) | Push-based event replication (`replicate-to-jotunheim`) | $\text{RTO} \approx 0\text{s}$, $\text{RPO} \approx 0\text{s}$ |
| **Authentication (OIDC)** | Authentik Hub (`auth.yggdrasil.local`) | APIServer OIDC federated to Yggdrasil Auth | Root CA trusted mount + Token verification | $\text{RTO} < 1\text{m}$, $\text{RPO} = 0\text{s}$ |
| **Relational Databases** | CloudNative-PG (`yggdrasil-pg`, `authentik-pg`) | CloudNative-PG Designated Standby | Continuous WAL streaming over Kilo WireGuard or S3 | $\text{RTO} < 2\text{m}$, $\text{RPO} < 5\text{s}$ |
| **Object Storage (S3)** | SeaweedFS S3 Active | SeaweedFS S3 Asynchronous Replicated Target | SeaweedFS `filer.sync` or S3 bucket replication | $\text{RTO} < 1\text{m}$, $\text{RPO} < 10\text{s}$ |
| **Git & CI/CD** | Forgejo Primary (`git.yggdrasil.local`) | Forgejo Mirror + Forgejo Runner | Git mirror push / bidirectional repository sync | $\text{RTO} < 1\text{m}$, $\text{RPO} \approx 0\text{s}$ |
| **DNS Authoritative** | CoreDNS Primary with DNSSEC (`ns1`) | CoreDNS Secondary / AXFR slave (`ns2`) | RFC 5936 AXFR / IXFR zone transfer over WireGuard | $\text{RTO} = 0\text{s}$, $\text{RPO} = 0\text{s}$ |
| **Telemetry & Alerts** | VictoriaMetrics + VMAlert + Grafana | VictoriaMetrics Scrape Agent + Remote Write | VMAgent Prometheus remote-write stream | $\text{RTO} = 0\text{s}$, $\text{RPO} < 5\text{s}$ |
| **Serverless & KEDA** | KEDA Core + HTTP Add-on (`fn.yggdrasil.local`) | KEDA Core + HTTP Add-on (`fn.jotunheim.local`) | Identical GitOps manifests reconciled by Flux | $\text{RTO} = 0\text{s}$, $\text{RPO} = 0\text{s}$ |

---

## 6. Implementation Checklist for Replicated Jotunheim

To deploy all components onto Jotunheim:
1. **GitOps Root (`clusters/jotunheim/`)**:
   - Provide `infrastructure.yaml` referencing `./infrastructure/overlays/jotunheim`.
   - Provide `apps.yaml` referencing `./apps/overlays/jotunheim`.
2. **Infrastructure Overlay (`infrastructure/overlays/jotunheim/`)**:
   - Inherits `infrastructure/base`.
   - Injects Kilo WireGuard peer routing to Yggdrasil (`10.4.0.0/16` $\leftrightarrow$ `10.5.0.0/16`).
   - Applies Pod Security Standards (`restricted`) and ResourceQuotas.
3. **Apps Overlay (`apps/overlays/jotunheim/`)**:
   - Inherits `apps/base`.
   - Deploys Harbor (configured with replication receiver).
   - Deploys CloudNativePG in replica mode (`yggdrasil-pg-standby`).
   - Deploys Bifrost Envoy Gateway with Jotunheim hostname listeners.
   - Deploys Authentik, Zulip, Mailserver, Forgejo, VictoriaMetrics, and KEDA serverless functions.
