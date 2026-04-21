# High-Level Design (HLD)
## AWS Transit Gateway Network Segmentation
### Healthcare Organization — Zero Trust Network Architecture

---

| Document Attribute | Value |
|---|---|
| Document ID | LAB2-HLD-001 |
| Version | 1.0 |
| Classification | Internal — Architecture |
| Compliance Scope | HIPAA, PCI-DSS, SOX |
| Author | Platform Engineering |
| Status | Approved |

---

## 1. Executive Summary

A healthcare organization operating Electronic Health Record (EHR) systems in AWS has identified a critical security gap: production, development, and shared services workloads share a flat, fully-peered VPC topology. Any network compromise in a development environment can traverse laterally to production databases containing Protected Health Information (PHI).

This design replaces flat VPC peering with an **AWS Transit Gateway (TGW) segmentation model** that enforces network-level isolation between environments using route table policy. The result is a zero-trust network posture where connectivity must be explicitly permitted — denied by default — at the infrastructure layer, independent of application-layer controls.

---

## 2. Business Context and Problem Statement

### 2.1 Current State (Flat Network — Risk Posture)

```
┌─────────────────────────────────────────────────────────────┐
│                    CURRENT STATE (FLAT)                      │
│                                                             │
│  Production VPC ←──── VPC Peering ────→ Dev VPC            │
│       │                                      │              │
│       └──────── VPC Peering ────→ Shared Services VPC       │
│                                                             │
│  Problem: Any-to-any reachability.                          │
│  A compromised dev EC2 can reach the EHR database           │
│  on port 3306 with no network enforcement.                  │
└─────────────────────────────────────────────────────────────┘
```

**Risk:** A developer's compromised workstation or a supply-chain attack on a dev dependency can pivot directly to production PHI databases. This violates:
- HIPAA minimum necessary access (§164.514(d))
- PCI-DSS network segmentation (Req 1.3)
- NIST SP 800-207 Zero Trust principle of explicit verification

### 2.2 Target State (TGW Segmentation)

```
┌─────────────────────────────────────────────────────────────┐
│                   TARGET STATE (SEGMENTED)                   │
│                                                             │
│  Production VPC → TGW prod-rt → NO route to dev CIDR       │
│  Dev VPC        → TGW nonprod-rt → NO route to prod CIDR   │
│  Both           → TGW → Shared Services (explicit allow)    │
│  All            → TGW → Centralized NAT (internet egress)   │
│                                                             │
│  Enforcement: infrastructure layer, not application layer.  │
│  Compromise in dev cannot reach prod — period.              │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Solution Overview

### 3.1 Core Design Principles

| Principle | Implementation |
|---|---|
| **Deny by Default** | TGW `default_route_table_association = disable` — no attachment has connectivity until explicitly configured |
| **Explicit Permit** | Route table propagations are the only mechanism that creates reachability; each one is a deliberate policy decision in code |
| **Blast Radius Containment** | Route table isolation caps the lateral movement radius of any compromise to its segment |
| **Centralized Egress** | All internet-bound traffic exits through one NAT Gateway in a dedicated networking account — single chokepoint for DLP/monitoring |
| **Immutable Audit Trail** | VPC flow logs delivered to a security-account S3 bucket with WORM-equivalent protection (versioning + lifecycle); 7-year HIPAA retention |
| **Infrastructure as Code** | All network policy (routes, propagations, blackholes) is Terraform — every change is code-reviewed, state-tracked, and reversible |

### 3.2 High-Level Component Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           AWS ACCOUNT (Lab Simulation)                   │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                      TRANSIT GATEWAY                               │  │
│  │                                                                    │  │
│  │  ┌──────────┐  ┌──────────┐  ┌────────────────┐  ┌────────────┐  │  │
│  │  │ prod-rt  │  │nonprod-rt│  │shared-svc-rt   │  │ egress-rt  │  │  │
│  │  └────┬─────┘  └────┬─────┘  └───────┬────────┘  └─────┬──────┘  │  │
│  └───────┼─────────────┼────────────────┼────────────────┼───────────┘  │
│          │             │                │                │              │
│  ┌───────▼──────┐ ┌────▼──────┐ ┌──────▼──────┐ ┌──────▼──────────┐   │
│  │ PRODUCTION   │ │    DEV    │ │  SHARED SVC  │ │  NETWORKING     │   │
│  │    VPC       │ │    VPC    │ │     VPC      │ │     VPC         │   │
│  │              │ │           │ │              │ │                 │   │
│  │ App Tier     │ │ Workloads │ │ AD / DNS /   │ │ IGW + NAT GW   │   │
│  │ EHR DB Tier  │ │           │ │ Patch Mgmt   │ │ (Egress only)  │   │
│  │ 10.0.0.0/16  │ │10.1.0.0/16│ │ 10.2.0.0/16  │ │ 10.3.0.0/16   │   │
│  └──────────────┘ └───────────┘ └──────────────┘ └─────────────────┘   │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  CENTRAL SECURITY ACCOUNT (SIMULATED)                              │  │
│  │  S3 Bucket: vpc-flow-logs | KMS CMK | 7-yr lifecycle | Versioned   │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Network Segmentation Model

### 4.1 Segments

| Segment | VPC CIDR | TGW Route Table | Purpose |
|---|---|---|---|
| **Production** | 10.0.0.0/16 | `prod-rt` | EHR workloads, PHI databases |
| **Non-Production** | 10.1.0.0/16 | `nonprod-rt` | Dev, test, CI/CD |
| **Shared Services** | 10.2.0.0/16 | `shared-services-rt` | Active Directory, DNS, patch management |
| **Networking** | 10.3.0.0/16 | `egress-rt` | Centralized internet egress (NAT Gateway) |
| **Inspection** | (reserved) | `inspection-rt` | Future: NFW/GWLB inline inspection |

### 4.2 Permitted Traffic Matrix

| Source → Destination | Prod DB | Dev Workload | Shared Svc | Internet |
|---|:---:|:---:|:---:|:---:|
| **Production** | ✓ | ✗ DENIED | ✓ | ✓ via NAT |
| **Dev** | ✗ DENIED | ✓ | ✓ | ✓ via NAT |
| **Shared Services** | ✓ | ✓ | ✓ | ✓ via NAT |

**Key enforcement point:** The DENIED cells are enforced at the TGW route table level. No route exists, plus explicit blackhole routes add a second layer of enforcement.

### 4.3 Enforcement Layering

```
Layer 1 (Infrastructure):   TGW Route Tables — no route = no packet delivery
Layer 2 (Infrastructure):   Blackhole Routes — explicit drop for critical CIDRs
Layer 3 (Network):          Security Groups  — stateful per-resource rules
Layer 4 (Network):          NACLs            — stateless subnet boundary rules
Layer 5 (Application):      IAM + App Auth   — identity-based access control
```

This design operates at Layers 1–2, independent of Layers 3–5. Even if a security group is misconfigured, TGW route isolation prevents the packet from arriving.

---

## 5. Centralized Egress Architecture

All internet-bound traffic from spoke VPCs is forced through a single NAT Gateway in the networking VPC. This provides:

1. **Single egress IP** — one EIP to whitelist in downstream partner firewalls and SaaS allowlists
2. **Chokepoint for monitoring** — all outbound connections visible in one place (flow logs on the networking VPC)
3. **Future DLP insertion point** — inline Network Firewall or 3rd-party appliance can be inserted in the networking VPC without modifying spoke VPCs

```
Spoke → TGW (0.0.0.0/0 static in spoke RT) → Networking VPC TGW subnet
     → TGW subnet RT (0.0.0.0/0 → NAT GW) → NAT Gateway → IGW → Internet
```

---

## 6. Flow Log Architecture

### 6.1 Centralized Security Account Pattern

```
Production VPC   ──┐
Dev VPC          ──┤──→  S3 Bucket (security account)
Shared Svc VPC   ──┤      vpc-flow-logs/{environment}/
Networking VPC   ──┘      Parquet format + Hive partitions
                           KMS CMK encrypted
                           7-year retention (HIPAA)
                           Versioning enabled
                           HTTPS-only + deny-unencrypted policy
```

### 6.2 Queryable with Amazon Athena

Flow logs stored in Parquet with Hive-compatible partitions (`year=`, `month=`, `day=`, `hour=`) enable SQL queries at low cost without full table scans:

```sql
-- Detect cross-segment denied traffic (audit evidence for HIPAA/PCI-DSS)
SELECT srcaddr, dstaddr, dstport, action, packets, bytes
FROM vpc_flow_logs
WHERE action = 'REJECT'
  AND srcaddr LIKE '10.1.%'   -- source: dev
  AND dstaddr LIKE '10.0.%'   -- destination: production
ORDER BY start DESC;
```

---

## 7. Compliance Alignment

### 7.1 HIPAA Technical Safeguards (§164.312)

| HIPAA Control | Requirement | This Design |
|---|---|---|
| §164.312(a)(1) | Access Control | TGW route isolation enforces network-level access control between environments |
| §164.312(a)(2)(i) | Unique User Identification | All EC2 instances in isolated segments; lateral movement prevented at network layer |
| §164.312(b) | Audit Controls | VPC flow logs, 7-year S3 retention, KMS encryption, immutable versioning |
| §164.312(e)(1) | Transmission Security | All inter-segment traffic enforced via TGW; non-prod cannot transmit to prod |
| §164.312(e)(2)(ii) | Encryption in Transit | KMS CMK on flow log bucket; HTTPS-only bucket policy |

### 7.2 PCI-DSS v4.0

| Requirement | Description | Implementation |
|---|---|---|
| 1.2.1 | Network security controls between all networks | TGW route tables are the NSC between production CDE and all other segments |
| 1.3.2 | Restrict inbound traffic to CDE to necessary | Only shared services propagates into `prod-rt`; dev cannot reach prod CIDR |
| 1.3.3 | Anti-spoofing measures | Blackhole routes prevent spoofed traffic leveraging route confusion |
| 10.2.1 | Audit log events | Flow logs capture all accepted and rejected flows per VNIC |
| 10.5.1 | Protect audit logs | S3 bucket with deny-delete policy, versioning, KMS CMK |

### 7.3 SOX IT General Controls

| ITGC Domain | Control | Implementation |
|---|---|---|
| Change Management | All network policy changes require code review and Terraform plan approval | TGW routes in version-controlled Terraform; changes visible in `terraform plan` diff |
| Access Management | Prod/non-prod separation | No operator can reach production from dev networks — enforced at infrastructure layer |
| Logical Security | Least-privilege network access | Propagation grants access; anything not propagated is denied |

### 7.4 NIST SP 800-207 Zero Trust Architecture

| ZTA Principle | Implementation |
|---|---|
| Verify Explicitly | Network access requires explicit TGW propagation — no implicit trust based on IP or subnet |
| Use Least Privilege | Minimum propagation set: dev ↔ shared-svc only; prod ↔ shared-svc only |
| Assume Breach | Blast radius is bounded to the segment; prod compromise cannot reach dev and vice versa |

---

## 8. Key Design Decisions

### 8.1 Transit Gateway vs. VPC Peering

| Aspect | VPC Peering | Transit Gateway |
|---|---|---|
| Segmentation enforcement | Requires NACLs + SGs per peering | Native route table isolation — single policy plane |
| Scalability | O(n²) peering connections | Hub-and-spoke — O(n) attachments |
| Centralized egress | Complex to force; requires overlapping CIDR exceptions | Native: static default route to networking attachment |
| Policy as code | Many individual peering + NACL resources | One TGW + route tables — simpler state |
| Compliance auditability | Distributed configuration — hard to audit | Centralized route policy — single source of truth |

**Decision:** TGW was chosen for its native segmentation model and single-pane policy enforcement.

### 8.2 Why Dedicated TGW Attachment Subnets

TGW attachment ENIs are placed in `/28` subnets dedicated solely to TGW infrastructure. Workload ENIs are in separate subnets. This prevents:
- Security group rules on workload resources from accidentally affecting TGW traffic processing
- ENI address space exhaustion in subnets shared with workloads
- Route table association conflicts between workload and TGW attachment subnets

### 8.3 Single NAT Gateway vs. Per-AZ

In this lab, `single_nat_gateway = true` reduces cost. The `networking_vpc` module accepts `single_nat_gateway = false` for production, which deploys one NAT GW per AZ with AZ-affinity routing (TGW attachment subnet → NAT GW in same AZ). This eliminates cross-AZ NAT traffic charges and removes NAT as an AZ-level single point of failure.

### 8.4 Blackhole Routes as Defense-in-Depth

Missing propagation is the primary enforcement: if `dev-attachment` doesn't propagate into `prod-rt`, TGW has no route and drops traffic. Blackhole routes are added as a second layer because:
- They survive accidental re-enablement of default propagation
- They create an explicit REJECT log entry in flow logs (vs. silent drop)
- They prevent future static route additions from accidentally creating a cross-segment path unless the blackhole is explicitly removed

---

## 9. Out of Scope (Lab 2)

The following are architectural extensions documented in the README but not deployed in this lab:

- **Inline inspection** (`inspection-rt` + AWS Network Firewall) — reserved route table exists
- **Multi-account TGW sharing** via AWS RAM — bucket policy is already multi-account ready
- **Egress filtering** — NAT GW is unfiltered; NFW can be inserted transparently
- **AWS Route 53 Resolver** — DNS forwarding between environments via shared services
- **VPN / Direct Connect attachment** — on-premises connectivity via TGW

---

## 10. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Propagation misconfiguration allows cross-segment access | Low | Critical | Blackhole routes as defense-in-depth; automated compliance scanning (AWS Config) |
| Flow log S3 bucket misconfigured — logs lost | Low | High | Bucket policy enforces delivery; versioning prevents deletion; lifecycle prevents premature expiry |
| Single NAT GW becomes AZ SPOF | Medium | Medium | `single_nat_gateway = false` promotes to per-AZ NAT GW with one variable change |
| TGW becomes regional availability dependency | Low | High | TGW is a managed service with AWS SLA; multi-region design is a future extension |
| Cost overrun from TGW data processing | Medium | Low | Flow logs help identify chatty cross-AZ flows; right-sizing can reduce data processing charges |
