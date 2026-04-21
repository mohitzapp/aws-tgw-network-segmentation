# Low-Level Design (LLD)
## AWS Transit Gateway Network Segmentation
### Healthcare Organization — Technical Specification

---

| Document Attribute | Value |
|---|---|
| Document ID | LAB2-LLD-001 |
| Version | 1.0 |
| Parent Document | LAB2-HLD-001 |
| Classification | Internal — Engineering |
| Author | Platform Engineering |

---

## 1. Transit Gateway — Detailed Specification

### 1.1 Resource Configuration

| Parameter | Value | Reason |
|---|---|---|
| `amazon_side_asn` | 64512 | Private BGP ASN; unique per AWS account |
| `auto_accept_shared_attachments` | `disable` | All attachment shares require explicit acceptance |
| `default_route_table_association` | `disable` | Prevents new attachments from accidentally joining a default RT |
| `default_route_table_propagation` | `disable` | Prevents automatic full-mesh propagation |
| `dns_support` | `enable` | Route 53 Resolver queries traverse TGW |
| `vpn_ecmp_support` | `enable` | ECMP across multiple VPN tunnels (future) |
| `multicast_support` | `disable` | Not required; saves TGW state overhead |

### 1.2 Route Tables

Five route tables are created. Each attachment is explicitly associated with exactly one route table (inbound policy) and propagates its CIDR into one or more route tables (outbound reachability grant).

#### Route Table: `prod-rt`

**Purpose:** Handles traffic originating from the production VPC.

| Entry Type | Destination | Next Hop | How Created |
|---|---|---|---|
| Propagated | 10.0.0.0/16 | prod-attachment | `prod` propagates into `prod-rt` |
| Propagated | 10.2.0.0/16 | shared-svc-attachment | `shared-svc` propagates into `prod-rt` |
| Propagated | 10.3.0.0/16 | networking-attachment | `networking` propagates into `prod-rt` |
| Static | 0.0.0.0/0 | networking-attachment | Default egress to NAT |
| Static/Blackhole | 10.1.0.0/16 | BLACKHOLE | Explicit deny: dev CIDR |

#### Route Table: `nonprod-rt`

**Purpose:** Handles traffic originating from the dev VPC.

| Entry Type | Destination | Next Hop | How Created |
|---|---|---|---|
| Propagated | 10.1.0.0/16 | dev-attachment | `dev` propagates into `nonprod-rt` |
| Propagated | 10.2.0.0/16 | shared-svc-attachment | `shared-svc` propagates into `nonprod-rt` |
| Propagated | 10.3.0.0/16 | networking-attachment | `networking` propagates into `nonprod-rt` |
| Static | 0.0.0.0/0 | networking-attachment | Default egress to NAT |
| Static/Blackhole | 10.0.0.0/16 | BLACKHOLE | Explicit deny: prod CIDR |

#### Route Table: `shared-services-rt`

**Purpose:** Handles traffic originating from the shared services VPC.

| Entry Type | Destination | Next Hop | How Created |
|---|---|---|---|
| Propagated | 10.0.0.0/16 | prod-attachment | `prod` propagates into `shared-services-rt` |
| Propagated | 10.1.0.0/16 | dev-attachment | `dev` propagates into `shared-services-rt` |
| Propagated | 10.2.0.0/16 | shared-svc-attachment | `shared-svc` propagates into `shared-services-rt` (self) |
| Propagated | 10.3.0.0/16 | networking-attachment | `networking` propagates into `shared-services-rt` |
| Static | 0.0.0.0/0 | networking-attachment | Default egress to NAT |

#### Route Table: `egress-rt`

**Purpose:** Handles traffic arriving at the networking VPC from TGW.

| Entry Type | Destination | Next Hop | How Created |
|---|---|---|---|
| Propagated | 10.0.0.0/16 | prod-attachment | `prod` propagates into `egress-rt` (return path) |
| Propagated | 10.1.0.0/16 | dev-attachment | `dev` propagates into `egress-rt` (return path) |
| Propagated | 10.2.0.0/16 | shared-svc-attachment | `shared-svc` propagates into `egress-rt` (return path) |
| Propagated | 10.3.0.0/16 | networking-attachment | `networking` propagates into `egress-rt` (self) |
| Static/Blackhole | 10.0.0.0/8 | BLACKHOLE | Catch-all deny for non-spoke RFC1918 ranges; more-specific /16 propagated routes override this |

#### Route Table: `inspection-rt`

**Purpose:** Reserved for future NFW/GWLB inline inspection. No attachments currently.

---

## 2. VPC Subnet Layout

### 2.1 Production VPC — 10.0.0.0/16

| Subnet Name | CIDR | AZ | Route Table | Purpose |
|---|---|---|---|---|
| `lab2-healthcare-production-workload-us-east-1a` | 10.0.1.0/24 | us-east-1a | workload-rt | App tier |
| `lab2-healthcare-production-workload-us-east-1b` | 10.0.2.0/24 | us-east-1b | workload-rt | App tier |
| `lab2-healthcare-production-db-us-east-1a` | 10.0.10.0/24 | us-east-1a | database-rt | EHR database tier |
| `lab2-healthcare-production-db-us-east-1b` | 10.0.11.0/24 | us-east-1b | database-rt | EHR database tier |
| `lab2-healthcare-production-tgw-us-east-1a` | 10.0.100.0/28 | us-east-1a | tgw-rt | TGW ENIs only |
| `lab2-healthcare-production-tgw-us-east-1b` | 10.0.100.16/28 | us-east-1b | tgw-rt | TGW ENIs only |

#### Production VPC Route Tables

**workload-rt** (associated with workload subnets):
| Destination | Target |
|---|---|
| 10.0.0.0/16 | local |
| 0.0.0.0/0 | TGW |

**database-rt** (associated with database subnets):
| Destination | Target |
|---|---|
| 10.0.0.0/16 | local |
| 0.0.0.0/0 | TGW |

**tgw-rt** (associated with TGW attachment subnets — local only):
| Destination | Target |
|---|---|
| 10.0.0.0/16 | local |

### 2.2 Dev VPC — 10.1.0.0/16

| Subnet Name | CIDR | AZ | Route Table | Purpose |
|---|---|---|---|---|
| `lab2-healthcare-dev-workload-us-east-1a` | 10.1.1.0/24 | us-east-1a | workload-rt | Dev workloads |
| `lab2-healthcare-dev-workload-us-east-1b` | 10.1.2.0/24 | us-east-1b | workload-rt | Dev workloads |
| `lab2-healthcare-dev-tgw-us-east-1a` | 10.1.100.0/28 | us-east-1a | tgw-rt | TGW ENIs only |
| `lab2-healthcare-dev-tgw-us-east-1b` | 10.1.100.16/28 | us-east-1b | tgw-rt | TGW ENIs only |

#### Dev VPC Route Tables

**workload-rt:**
| Destination | Target |
|---|---|
| 10.1.0.0/16 | local |
| 0.0.0.0/0 | TGW |

### 2.3 Shared Services VPC — 10.2.0.0/16

| Subnet Name | CIDR | AZ | Route Table | Purpose |
|---|---|---|---|---|
| `lab2-healthcare-shared-services-workload-us-east-1a` | 10.2.1.0/24 | us-east-1a | workload-rt | AD, DNS, patch |
| `lab2-healthcare-shared-services-workload-us-east-1b` | 10.2.2.0/24 | us-east-1b | workload-rt | AD, DNS, patch |
| `lab2-healthcare-shared-services-tgw-us-east-1a` | 10.2.100.0/28 | us-east-1a | tgw-rt | TGW ENIs only |
| `lab2-healthcare-shared-services-tgw-us-east-1b` | 10.2.100.16/28 | us-east-1b | tgw-rt | TGW ENIs only |

### 2.4 Networking VPC — 10.3.0.0/16

| Subnet Name | CIDR | AZ | Route Table | Purpose |
|---|---|---|---|---|
| `lab2-healthcare-networking-public-us-east-1a` | 10.3.1.0/24 | us-east-1a | public-rt | NAT Gateway |
| `lab2-healthcare-networking-public-us-east-1b` | 10.3.2.0/24 | us-east-1b | public-rt | NAT Gateway |
| `lab2-healthcare-networking-tgw-us-east-1a` | 10.3.100.0/28 | us-east-1a | tgw-rt-us-east-1a | TGW ENIs only |
| `lab2-healthcare-networking-tgw-us-east-1b` | 10.3.100.16/28 | us-east-1b | tgw-rt-us-east-1b | TGW ENIs only |

#### Networking VPC Route Tables

**public-rt** (shared across all public subnets):
| Destination | Target | Purpose |
|---|---|---|
| 10.3.0.0/16 | local | VPC local |
| 0.0.0.0/0 | IGW | Internet egress for NAT GW |
| 10.0.0.0/8 | TGW | Return path: NAT GW → TGW → spoke VPC |

**tgw-rt-us-east-1a** (TGW attachment subnet in AZ-a):
| Destination | Target | Purpose |
|---|---|---|
| 10.3.0.0/16 | local | VPC local |
| 0.0.0.0/0 | nat-gw-us-east-1a | Forward spoke internet traffic to NAT GW (same AZ) |

**tgw-rt-us-east-1b** (TGW attachment subnet in AZ-b):
| Destination | Target | Purpose |
|---|---|---|
| 10.3.0.0/16 | local | VPC local |
| 0.0.0.0/0 | nat-gw-us-east-1a | Lab: single NAT GW; in prod use nat-gw-us-east-1b |

---

## 3. TGW Attachment Propagation Matrix (Complete)

This is the authoritative record of all `aws_ec2_transit_gateway_route_table_propagation` resources.

| Attachment | prod-rt | nonprod-rt | shared-svc-rt | egress-rt | inspection-rt |
|---|:---:|:---:|:---:|:---:|:---:|
| `production` | ✓ | — | ✓ | ✓ | — |
| `dev` | — | ✓ | ✓ | ✓ | — |
| `shared-services` | ✓ | ✓ | ✓ | ✓ | — |
| `networking` | — | — | — | ✓ | — |

**Legend:** ✓ = propagation exists (CIDR reachable from this RT) · — = no propagation (CIDR absent from RT)

**Key isolation facts:**
- `production` CIDR (10.0.0.0/16) is **absent** from `nonprod-rt` → dev has no route to prod
- `dev` CIDR (10.1.0.0/16) is **absent** from `prod-rt` → prod has no route to dev
- `networking` CIDR (10.3.0.0/16) propagates into `egress-rt` only — the networking VPC cannot be a pivot between spoke segments

---

## 4. Security Controls Specification

### 4.1 Default Security Group (All VPCs)

The `aws_default_security_group` resource in every VPC is set to no rules — no inbound, no outbound. This overrides AWS's default behavior of creating an allow-all security group that applies to all resources not explicitly assigned an SG.

```hcl
resource "aws_default_security_group" "deny_all" {
  vpc_id = aws_vpc.this.id
  # No ingress or egress blocks = deny all
}
```

### 4.2 VPC Flow Log Configuration

| Parameter | Value |
|---|---|
| Traffic type | `ALL` (ACCEPT + REJECT) |
| Log destination type | `s3` |
| File format | `parquet` |
| Hive-compatible partitions | `true` (`year=YYYY/month=MM/day=DD/hour=HH`) |
| Per-hour partition | `true` |
| S3 prefix | `vpc-flow-logs/{environment}/` |

**Flow log field order** (default extended fields):
`version, account-id, interface-id, srcaddr, dstaddr, srcport, dstport, protocol, packets, bytes, start, end, action, log-status, vpc-id, subnet-id, instance-id, tcp-flags, type, pkt-srcaddr, pkt-dstaddr, region, az-id, sublocation-type, sublocation-id, pkt-src-aws-service, pkt-dst-aws-service, flow-direction, traffic-path`

### 4.3 S3 Bucket Security Controls

| Control | Configuration |
|---|---|
| Public access | All public access blocked (`block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets` = true) |
| Encryption | SSE-KMS with CMK (`bucket_key_enabled = true` to reduce KMS API calls) |
| Versioning | Enabled |
| Object lifecycle | 90d → IA, 365d → Glacier, 2557d → Expire |
| HTTPS enforcement | Bucket policy `DenyNonSSLRequests` (denies `aws:SecureTransport = false`) |
| Unencrypted upload prevention | Bucket policy `DenyUnencryptedObjectUploads` (denies `s3:x-amz-server-side-encryption ≠ aws:kms`) |

### 4.4 KMS Key Policy

| Statement | Principal | Actions | Condition |
|---|---|---|---|
| `EnableRootAccess` | Account root | `kms:*` | None |
| `AllowFlowLogsServiceEncrypt` | `delivery.logs.amazonaws.com` | `GenerateDataKey`, `Decrypt` | None |
| `AllowS3ServiceEncrypt` | `s3.amazonaws.com` | `GenerateDataKey`, `Decrypt` | None |

Key rotation is enabled (`enable_key_rotation = true`). Deletion window is 30 days.

---

## 5. Terraform Module Interface Reference

### 5.1 `modules/transit_gateway`

**Inputs:**

| Variable | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Resource name (e.g., `lab2-healthcare-tgw`) |
| `description` | string | `"Transit Gateway for network segmentation"` | TGW description |
| `amazon_side_asn` | number | `64512` | BGP ASN |
| `tags` | map(string) | `{}` | Additional tags |

**Outputs:**

| Output | Description |
|---|---|
| `tgw_id` | TGW resource ID |
| `tgw_arn` | TGW ARN |
| `rt_production_id` | prod-rt route table ID |
| `rt_nonproduction_id` | nonprod-rt route table ID |
| `rt_shared_services_id` | shared-services-rt route table ID |
| `rt_egress_id` | egress-rt route table ID |
| `rt_inspection_id` | inspection-rt route table ID |

### 5.2 `modules/spoke_vpc`

**Inputs:**

| Variable | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | VPC name |
| `environment` | string | required | `production`, `dev`, `shared-services` |
| `segment` | string | required | TGW segment label (used in tags) |
| `vpc_cidr` | string | required | VPC CIDR block |
| `tgw_id` | string | required | TGW ID |
| `associate_route_table_id` | string | required | TGW RT for inbound association |
| `propagate_to_route_table_ids` | list(string) | required | RTs to propagate this VPC's CIDR into |
| `workload_subnets` | list({cidr, az}) | required | App tier subnets |
| `database_subnets` | list({cidr, az}) | `[]` | DB tier subnets (empty = omit DB RT) |
| `tgw_subnets` | list({cidr, az}) | required | /28 subnets for TGW ENIs |
| `flow_log_bucket_arn` | string | `""` | S3 ARN for flow logs (empty = disable) |
| `tags` | map(string) | `{}` | Additional tags |

**Outputs:**

| Output | Description |
|---|---|
| `vpc_id` | VPC ID |
| `vpc_cidr` | VPC CIDR |
| `tgw_attachment_id` | TGW attachment ID (used in root for static routes) |
| `workload_subnet_ids` | List of workload subnet IDs |
| `database_subnet_ids` | List of database subnet IDs |
| `tgw_subnet_ids` | List of TGW attachment subnet IDs |
| `workload_route_table_id` | Workload RT ID |
| `database_route_table_id` | Database RT ID (null if no DB subnets) |
| `flow_log_id` | Flow log resource ID |

### 5.3 `modules/networking_vpc`

**Inputs:**

| Variable | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | VPC name |
| `vpc_cidr` | string | required | Must not overlap spokes |
| `tgw_id` | string | required | TGW ID |
| `associate_route_table_id` | string | required | Should be `rt_egress_id` |
| `propagate_to_route_table_ids` | list(string) | `[]` | Usually `[rt_egress_id]` |
| `public_subnets` | list({cidr, az}) | required | NAT GW subnets |
| `tgw_subnets` | list({cidr, az}) | required | /28 TGW attachment subnets |
| `spoke_cidr_supernet` | string | `"10.0.0.0/8"` | Supernet for return route in public RT |
| `single_nat_gateway` | bool | `true` | Lab: one NAT GW; prod: false for per-AZ |
| `flow_log_bucket_arn` | string | `""` | S3 ARN |
| `tags` | map(string) | `{}` | Additional tags |

**Outputs:**

| Output | Description |
|---|---|
| `vpc_id` | VPC ID |
| `tgw_attachment_id` | TGW attachment ID (used in root for default egress static routes) |
| `internet_gateway_id` | IGW ID |
| `nat_gateway_ids` | map(AZ → NAT GW ID) |
| `nat_public_ips` | map(AZ → EIP public IP) — whitelist this IP downstream |

### 5.4 `modules/flow_logs`

**Inputs:**

| Variable | Type | Default | Description |
|---|---|---|---|
| `prefix` | string | required | Bucket naming prefix |
| `source_account_ids` | list(string) | `[]` | Accounts allowed to deliver logs (defaults to current account) |
| `force_destroy` | bool | `false` | Allow bucket destroy with objects |
| `tags` | map(string) | `{}` | Additional tags |

**Outputs:**

| Output | Description |
|---|---|
| `bucket_arn` | S3 bucket ARN — passed to all VPC modules |
| `bucket_name` | S3 bucket name |
| `kms_key_arn` | KMS CMK ARN |
| `kms_key_id` | KMS CMK ID |

---

## 6. Root Module Resource Dependency Graph

```
module.flow_logs                        (no deps)
     │
     ├──────────────────────────────────┐
     ▼                                  │
module.transit_gateway                  │  (no deps)
     │                                  │
     ├─────────────────────────────────┐│
     ▼                                 ▼▼
module.production_vpc          module.networking_vpc
module.dev_vpc                  (depends on: tgw, flow_logs)
module.shared_services_vpc
  (depends on: tgw, flow_logs)
     │                                  │
     └──────────────────┬───────────────┘
                        ▼
         Root: aws_ec2_transit_gateway_route.*
         (depends on: all tgw_attachment_ids + all rt_*_ids)
```

**Why static routes live in root `main.tf`:** Each static route crosses module boundaries — it needs a route table ID (from `transit_gateway` module) and an attachment ID (from a spoke or networking module). Terraform modules cannot import outputs from sibling modules, so the root module is the coordination point.

---

## 7. Resource Inventory

| Resource Type | Count | Description |
|---|---|---|
| `aws_ec2_transit_gateway` | 1 | TGW |
| `aws_ec2_transit_gateway_route_table` | 5 | prod, nonprod, shared-svc, egress, inspection |
| `aws_ec2_transit_gateway_vpc_attachment` | 4 | One per VPC |
| `aws_ec2_transit_gateway_route_table_association` | 4 | One per attachment |
| `aws_ec2_transit_gateway_route_table_propagation` | 11 | Per propagation matrix above |
| `aws_ec2_transit_gateway_route` (static) | 7 | 3 default egress + 2 blackhole spokes + 1 egress blackhole + 1 spoke return |
| `aws_vpc` | 4 | prod, dev, shared-svc, networking |
| `aws_subnet` | 20 | 6 prod + 4 dev + 4 shared-svc + 6 networking |
| `aws_route_table` | 11 | Per VPC tier (workload, db where applicable, tgw) + networking public |
| `aws_route` | ~16 | Default TGW routes in spoke RTs + NAT/IGW/RFC1918 routes in networking |
| `aws_internet_gateway` | 1 | Networking VPC |
| `aws_eip` | 1 | NAT GW EIP (lab: single) |
| `aws_nat_gateway` | 1 | Lab: single; prod: 2 |
| `aws_flow_log` | 4 | One per VPC |
| `aws_s3_bucket` | 1 | Central flow log archive |
| `aws_kms_key` | 1 | Flow log encryption CMK |
| `aws_kms_alias` | 1 | Human-readable alias for CMK |
| `aws_s3_bucket_policy` | 1 | Multi-account delivery + HTTPS enforcement |
| `aws_default_security_group` | 4 | Deny-all override in each VPC |
| **Total** | **~100** | |

---

## 8. Naming Convention

All resources follow: `{prefix}-{component}-{tier?}-{az?}`

| Example | Pattern |
|---|---|
| `lab2-healthcare-tgw` | `{prefix}-tgw` |
| `lab2-healthcare-production` | `{prefix}-{environment}` (VPC) |
| `lab2-healthcare-production-workload-us-east-1a` | `{prefix}-{env}-workload-{az}` (subnet) |
| `lab2-healthcare-prod-rt` | `{prefix}-prod-rt` (TGW route table) |
| `lab2-healthcare-networking-nat-gw-us-east-1a` | `{prefix}-networking-nat-gw-{az}` |
| `lab2-healthcare-vpc-flow-logs-{account_id}` | `{prefix}-vpc-flow-logs-{account}` (S3) |

---

## 9. Tagging Strategy

### Default Tags (applied via AWS provider `default_tags`)

| Tag | Value | Purpose |
|---|---|---|
| `Project` | `Lab2-TGW-Segmentation` | Cost allocation |
| `ManagedBy` | `terraform` | Identifies IaC-managed resources |
| `Owner` | `platform-engineering` | Ops ownership |
| `CostCenter` | `infra-labs` | Billing |

### Per-Resource Tags

| Tag | Where Applied | Example Values |
|---|---|---|
| `Name` | All | `lab2-healthcare-production` |
| `Environment` | VPCs, subnets | `production`, `dev`, `shared-services` |
| `Segment` | VPCs, TGW RTs | `production`, `nonproduction`, `shared-services`, `networking` |
| `Tier` | Subnets | `workload`, `database`, `tgw-attachment`, `public` |
| `DataClassification` | VPCs (prod) | `PHI` |
| `ComplianceScope` | Flow logs bucket | `HIPAA,PCI-DSS` |
| `HIPAARetention` | S3 bucket | `7-years` |

---

## 10. Validation Test Cases

After `terraform apply`, validate the segmentation with the following tests. All tests run from EC2 instances in respective VPC workload subnets.

| Test ID | Source | Destination | Port | Expected Result | Validates |
|---|---|---|---|---|---|
| TC-01 | Dev (10.1.1.x) | Prod DB (10.0.10.x) | 3306 | **TIMEOUT** (TGW drops) | Core segmentation |
| TC-02 | Dev (10.1.1.x) | Prod App (10.0.1.x) | 443 | **TIMEOUT** (TGW drops) | Core segmentation |
| TC-03 | Prod (10.0.1.x) | Dev (10.1.1.x) | 22 | **TIMEOUT** (TGW drops) | Bidirectional isolation |
| TC-04 | Dev (10.1.1.x) | Shared Svc (10.2.1.x) | 53 | **CONNECT** (route exists) | Selective reachability |
| TC-05 | Prod (10.0.1.x) | Shared Svc (10.2.1.x) | 53 | **CONNECT** (route exists) | Selective reachability |
| TC-06 | Dev (10.1.1.x) | 8.8.8.8 | 443 | **CONNECT** (via NAT) | Centralized egress |
| TC-07 | Prod (10.0.1.x) | 8.8.8.8 | 443 | **CONNECT** (via NAT) | Centralized egress |
| TC-08 | Flow logs bucket | REJECT entries for TC-01..03 | — | **Present in S3** | Audit trail |

**Note on TC-01 expected behavior:** The connection will hang (timeout) rather than receiving a TCP RST. This is because TGW silently drops packets for which no route exists (blackhole). Flow logs on the dev VPC will show `REJECT` with `dstaddr=10.0.10.x`.
