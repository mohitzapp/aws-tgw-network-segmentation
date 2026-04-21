# Lab 2 — AWS Transit Gateway Network Segmentation

**Scenario:** A healthcare organization runs production, development, and shared services in flat-peered VPCs. A single compromised dev instance can laterally traverse to the EHR production database. This lab converts that flat network into an enforced blast-radius model using AWS Transit Gateway route table segmentation.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           AWS Transit Gateway                            │
│                                                                          │
│  ┌───────────┐  ┌───────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │  prod-rt  │  │nonprod-rt │  │shared-services-rt│  │  egress-rt   │  │
│  └─────┬─────┘  └─────┬─────┘  └────────┬─────────┘  └──────┬───────┘  │
└────────┼──────────────┼─────────────────┼───────────────────┼───────────┘
         │              │                 │                   │
   ┌─────▼──────┐  ┌────▼─────┐  ┌───────▼───────┐  ┌───────▼────────┐
   │ Production │  │   Dev    │  │Shared Services│  │  Networking    │
   │    VPC     │  │   VPC    │  │     VPC       │  │     VPC        │
   │            │  │          │  │               │  │                │
   │ App Tier   │  │ Workload │  │  AD / DNS /   │  │  NAT Gateway   │
   │ EHR DB     │  │ Subnets  │  │  Patch Mgmt   │  │  (Internet     │
   │            │  │          │  │               │  │   Egress)      │
   │10.0.0.0/16 │  │10.1.0.0/ │  │ 10.2.0.0/16  │  │ 10.3.0.0/16   │
   └────────────┘  │   /16    │  └───────────────┘  └────────────────┘
                   └──────────┘

  ✗ Dev → Production:    DENIED (no route + blackhole)
  ✓ Dev → Shared Svc:    ALLOWED (propagation)
  ✓ Prod → Shared Svc:   ALLOWED (propagation)
  ✗ Prod → Dev:          DENIED (no route + blackhole)
  ✓ All → Internet:      Via centralized NAT Gateway
  ✓ All flow logs:       Central S3 (simulated security account)
```

---

## Segmentation Model

### TGW Route Tables

| Route Table | Associated VPC | What it knows |
|---|---|---|
| `prod-rt` | Production | Prod CIDR, Shared Svc CIDR, 0.0.0.0/0 → NAT |
| `nonprod-rt` | Dev | Dev CIDR, Shared Svc CIDR, 0.0.0.0/0 → NAT |
| `shared-services-rt` | Shared Svc | All CIDRs, 0.0.0.0/0 → NAT |
| `egress-rt` | Networking | All spoke CIDRs (for return traffic), /8 blackhole |
| `inspection-rt` | (reserved) | Future NFW/GWLB inline inspection |

### Propagation Matrix

| Attachment | prod-rt | nonprod-rt | shared-svc-rt | egress-rt |
|---|:---:|:---:|:---:|:---:|
| Production | YES | **NO** | YES | YES |
| Dev | **NO** | YES | YES | YES |
| Shared Services | YES | YES | YES | YES |
| Networking | — | — | — | YES |

**Key:** Dev does NOT propagate into prod-rt. Production does NOT propagate into nonprod-rt. This means neither VPC has a route to the other — TGW drops the traffic. Blackhole routes add an explicit deny as defense-in-depth.

---

## File Structure

```
Lab2/
├── main.tf                         # Root orchestration + TGW static routes
├── variables.tf                    # Input variable declarations
├── outputs.tf                      # Key resource outputs
├── provider.tf                     # AWS provider + Terraform version constraints
├── terraform.tfvars                # Active variable values
├── terraform.tfvars.example        # Safe-to-commit template
└── modules/
    ├── transit_gateway/            # TGW resource + 5 route tables
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── spoke_vpc/                  # Reusable: prod, dev, shared services VPCs
    │   ├── main.tf                 # VPC, subnets, TGW attachment, association,
    │   ├── variables.tf            # propagation, route tables, flow logs,
    │   └── outputs.tf              # default SG deny-all
    ├── networking_vpc/             # Centralized egress: IGW + NAT GW + TGW attachment
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── flow_logs/                  # Central S3 bucket + KMS + lifecycle + bucket policy
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## Quick Start

### Prerequisites

- Terraform >= 1.5.0
- AWS CLI configured (`aws configure` or environment variables)
- IAM permissions: `ec2:*`, `s3:*`, `kms:*`, `logs:*`, `iam:*`

### Deploy

```bash
cd Lab2

# Review the plan
terraform init
terraform plan

# Deploy
terraform apply

# Outputs include VPC IDs, TGW IDs, NAT public IPs, and flow log bucket name
terraform output
```

### Estimated Cost (us-east-1, single NAT GW)

| Resource | Monthly cost |
|---|---|
| Transit Gateway | ~$36 (attachment × 4 + data processing) |
| NAT Gateway | ~$32 (single, light traffic) |
| S3 flow logs (empty) | ~$0.02 |
| KMS key | ~$1 |
| **Total (lab)** | **~$70/month** |

Stop cost: `terraform destroy` tears down everything. The S3 bucket is `force_destroy = true` in lab mode.

---

## Demo Narrative

### Act 1 — Show the Problem (Flat Network)

In a flat VPC-peered setup, any workload can reach any other. A compromised dev EC2 instance at `10.1.1.x` can send TCP/3306 directly to the EHR database at `10.0.10.x`. There is no enforcement layer — only security groups, which rely on human discipline to maintain.

### Act 2 — Deploy the Segmented Network

```bash
terraform apply
```

Terraform creates:
1. The Transit Gateway with 5 isolated route tables
2. Four VPCs, each with dedicated TGW attachment subnets
3. All associations and propagations enforcing the segmentation matrix
4. Blackhole routes as defense-in-depth
5. Central flow log bucket with HIPAA-grade retention

### Act 3 — Demonstrate Dev Cannot Reach Prod

Launch a test EC2 instance in the dev VPC workload subnet and attempt to reach a resource in the production database subnet:

```bash
# From dev instance (10.1.1.x) — this WILL FAIL
ping 10.0.10.5         # production DB subnet
nc -zv 10.0.10.5 3306  # TCP to RDS port
```

**Why it fails:** The dev VPC's default route sends traffic to TGW. TGW looks up `10.0.10.5` in `nonprod-rt`. There is no route for `10.0.0.0/16` in `nonprod-rt` (production did not propagate there). Additionally, a blackhole route for `10.0.0.0/16` explicitly drops the traffic. The packet never reaches the production VPC.

### Act 4 — Add Shared Services (Selective Reachability)

The shared services VPC is already deployed. Verify both prod and dev can reach it:

```bash
# From dev instance — this SUCCEEDS
ping 10.2.1.5       # shared services AD/DNS subnet

# From prod instance — this ALSO SUCCEEDS
ping 10.2.1.5

# But from dev — prod is STILL unreachable
ping 10.0.1.5       # DENIED
```

**Why shared services works:** The shared services attachment propagates its CIDR (`10.2.0.0/16`) into both `prod-rt` and `nonprod-rt`. Prod and dev have routes to shared services, but not to each other.

### Act 5 — Pull Flow Logs as Proof of Enforcement

After running the denied traffic above, query the S3 bucket:

```bash
# Install AWS CLI S3 access
aws s3 ls s3://$(terraform output -raw flow_logs_bucket_name)/vpc-flow-logs/dev/

# Use Athena for SQL-based analysis
# Create table pointing to:
# s3://<bucket>/vpc-flow-logs/dev/
# then query:
SELECT srcaddr, dstaddr, dstport, action, packets
FROM vpc_flow_logs
WHERE action = 'REJECT'
  AND dstaddr LIKE '10.0.%'    -- destination is production CIDR
ORDER BY start DESC
LIMIT 50;
```

The `REJECT` records with `dstaddr` in `10.0.x.x` from `srcaddr` in `10.1.x.x` are auditable proof that the TGW route table isolation is working. This output maps directly to:

- **HIPAA §164.312(a)(1)** — Access Control: unique user access
- **HIPAA §164.312(e)(1)** — Transmission Security
- **PCI-DSS Req 1.3** — Restrict inbound and outbound traffic to what is necessary
- **SOX ITGC** — Network segmentation between production and non-production environments

---

## Centralized Egress Flow

```
Spoke workload (10.0.1.5) → internet (8.8.8.8)

1.  Spoke VPC route table: 0.0.0.0/0 → TGW
2.  TGW prod-rt:           0.0.0.0/0 → networking-attachment  (static route)
3.  Networking VPC TGW subnet RT: 0.0.0.0/0 → NAT Gateway
4.  NAT Gateway:           SNAT src=10.0.1.5 → public EIP
5.  IGW:                   packet → internet

Return path:
6.  Internet → IGW → NAT GW (DNAT back to 10.0.1.5)
7.  NAT GW in public subnet RT: 10.0.0.0/8 → TGW
8.  TGW egress-rt:         10.0.0.0/16 → prod-attachment  (propagated)
9.  Production VPC:        packet delivered to 10.0.1.5 ✓
```

All VPC flow logs for this path appear under:
`s3://<bucket>/vpc-flow-logs/production/` and `s3://<bucket>/vpc-flow-logs/networking/`

---

## Compliance Mapping

| Control | Implementation |
|---|---|
| HIPAA §164.312(a)(1) Access Control | TGW route table isolation enforces network-level access control independently of application-layer controls |
| HIPAA §164.312(b) Audit Controls | VPC flow logs with 7-year S3 retention, KMS encryption, versioning |
| PCI-DSS Req 1.2 — Network segmentation | Production CDE isolated from non-production by TGW blackhole routes |
| PCI-DSS Req 10.2 — Log events | All REJECT/ACCEPT flows captured per-hour in Parquet for Athena cost-efficient querying |
| SOX ITGC — Change Management | Terraform state tracks every route table change; propagation matrix is code-reviewed |
| NIST SP 800-207 Zero Trust | Network segmentation is the first concrete ZT control — explicit deny by default, propagation grants selective access |

---

## Extending This Lab

### Add an Inspection VPC (NFW)

1. Deploy AWS Network Firewall in a new inspection VPC
2. Associate the inspection VPC attachment with `inspection-rt`
3. Route specific flows through `inspection-rt` using more-specific TGW static routes
4. Add NFW policy rules (Suricata-compatible) for IDS/IPS

### Promote to Multi-Account

1. Share the TGW via AWS Resource Access Manager (RAM) to each account
2. Each account accepts the TGW share and creates its own VPC attachment
3. The S3 flow log bucket policy already supports `source_account_ids = [list]`
4. Add `aws:SourceOrg` condition for full AWS Organizations scope

### Add a Maintenance Bypass (Break-Glass)

```hcl
# Temporarily add to prod-rt for emergency maintenance window
resource "aws_ec2_transit_gateway_route" "break_glass_dev_to_prod" {
  count                          = var.break_glass_enabled ? 1 : 0
  destination_cidr_block         = var.production_vpc_cidr
  transit_gateway_attachment_id  = module.production_vpc.tgw_attachment_id
  transit_gateway_route_table_id = module.transit_gateway.rt_nonproduction_id
}
```

Set `break_glass_enabled = true` in tfvars, apply, remediate, revert. Every change is in git history and Terraform state.
