# Process Architecture
## AWS Transit Gateway Network Segmentation
### Use Case and Steps Centric Reference

---

| Document Attribute | Value |
|---|---|
| Document ID | LAB2-PROC-001 |
| Version | 1.0 |
| Parent Documents | LAB2-HLD-001, LAB2-LLD-001 |
| Classification | Internal — Operations |
| Author | Platform Engineering |

---

## Overview

This document describes the operational processes and end-to-end step flows for every use case in the Lab 2 TGW segmentation environment. It covers:

- **Traffic use cases** — packet-level step flows for each permitted and denied communication path
- **Operational use cases** — how to deploy, change, and tear down the environment
- **Incident use cases** — how to investigate a suspected cross-segment access
- **Compliance use cases** — how to produce audit evidence on demand

---

## Use Case Index

| ID | Use Case | Type | Outcome |
|---|---|---|---|
| UC-01 | Dev instance attempts to reach production EHR database | Traffic | DENIED |
| UC-02 | Dev instance accesses shared services (DNS/AD) | Traffic | PERMITTED |
| UC-03 | Production app accesses shared services (patch management) | Traffic | PERMITTED |
| UC-04 | Production workload accesses the internet | Traffic | PERMITTED via NAT |
| UC-05 | Dev workload accesses the internet | Traffic | PERMITTED via NAT |
| UC-06 | Production attempts to reach dev workload | Traffic | DENIED |
| UC-07 | Initial deployment — stand up the full environment | Operations | Deploy |
| UC-08 | Add a new spoke VPC to the environment | Operations | Change |
| UC-09 | Temporary break-glass: grant emergency dev → prod access | Operations | Change + Revert |
| UC-10 | Security investigation: confirm cross-segment attempt | Incident Response | Audit |
| UC-11 | Compliance audit: produce HIPAA flow log evidence | Compliance | Reporting |

---

## UC-01 — Dev Attempts to Reach Production EHR Database

**Scenario:** A compromised dev EC2 instance or misconfigured pipeline attempts to connect to the production RDS instance at `10.0.10.5:3306`.

**Actors:** Dev EC2 (10.1.1.x), Production RDS (10.0.10.5)

### Step Flow

```
Step 1: Dev EC2 initiates TCP SYN to 10.0.10.5:3306
        Source: 10.1.1.50 → Destination: 10.0.10.5:3306

Step 2: Dev VPC workload-rt lookup
        Destination 10.0.10.5 matches 0.0.0.0/0 → TGW
        (no more-specific route for 10.0.0.0/16 exists in the VPC)
        ENI sends packet to TGW attachment in tgw subnet

Step 3: TGW receives packet on dev VPC attachment
        TGW looks up source attachment → finds association: nonprod-rt
        TGW performs route lookup in nonprod-rt for 10.0.10.5

Step 4: nonprod-rt lookup
        ┌─ Table entries ──────────────────────────────────────────┐
        │  10.1.0.0/16   → dev-attachment (propagated)             │
        │  10.2.0.0/16   → shared-svc-attachment (propagated)      │
        │  10.3.0.0/16   → networking-attachment (propagated)      │
        │  0.0.0.0/0     → networking-attachment (static)          │
        │  10.0.0.0/16   → BLACKHOLE (static)          ← MATCH     │
        └──────────────────────────────────────────────────────────┘
        10.0.10.5 matches 10.0.0.0/16 → BLACKHOLE

Step 5: TGW drops packet (blackhole)
        Packet is silently discarded — no TCP RST sent
        Dev EC2 experiences connection timeout

Step 6: VPC Flow Log written (dev VPC, dev ENI)
        srcaddr=10.1.1.50  dstaddr=10.0.10.5  dstport=3306
        protocol=6 (TCP)   action=REJECT       packets=1

Step 7: Flow log delivered to S3
        s3://{bucket}/vpc-flow-logs/dev/year=.../month=.../day=.../hour=.../
        File: parquet, Hive-partitioned
```

**Outcome:** DENIED. Connection times out. REJECT entry written to flow logs. No traffic reaches the production VPC.

---

## UC-02 — Dev Instance Accesses Shared Services (DNS/AD)

**Scenario:** Dev EC2 (10.1.1.50) resolves a hostname via the Active Directory DNS server at `10.2.1.10:53`.

**Actors:** Dev EC2 (10.1.1.x), Shared Services DNS (10.2.1.10)

### Step Flow

```
Step 1: Dev EC2 sends UDP packet to 10.2.1.10:53
        Source: 10.1.1.50:49152 → Destination: 10.2.1.10:53

Step 2: Dev VPC workload-rt lookup
        Destination 10.2.1.10 matches 0.0.0.0/0 → TGW
        Packet forwarded via TGW attachment (10.1.100.x subnet)

Step 3: TGW receives packet on dev VPC attachment
        Source attachment → association: nonprod-rt
        Route lookup in nonprod-rt for 10.2.1.10

Step 4: nonprod-rt lookup
        ┌─────────────────────────────────────────────────────────┐
        │  10.2.0.0/16   → shared-svc-attachment (propagated) ← MATCH │
        └──────────────────────────────────────────────────────────┘
        Longest-prefix match: 10.2.0.0/16 wins over 0.0.0.0/0
        Next hop: shared-svc-attachment

Step 5: TGW forwards packet to shared-svc attachment
        Packet delivered to shared services TGW attachment subnet (10.2.100.x)

Step 6: Shared services TGW subnet → workload subnet
        Shared svc VPC local route: 10.2.0.0/16 → local
        Packet delivered to DNS server ENI at 10.2.1.10

Step 7: DNS server processes query, sends response
        Source: 10.2.1.10:53 → Destination: 10.1.1.50:49152

Step 8: Shared svc VPC workload-rt lookup
        Destination 10.1.1.50 matches 0.0.0.0/0 → TGW

Step 9: TGW receives return packet on shared-svc attachment
        Source attachment → association: shared-services-rt
        Route lookup in shared-services-rt for 10.1.1.50

Step 10: shared-services-rt lookup
         10.1.0.0/16 → dev-attachment (propagated) ← MATCH
         Packet forwarded to dev-attachment

Step 11: Dev VPC receives packet
         Delivered to dev EC2 at 10.1.1.50

Step 12: Flow logs written on both VPCs
         dev VPC:         srcaddr=10.1.1.50  dstaddr=10.2.1.10  action=ACCEPT
         shared-svc VPC:  srcaddr=10.1.1.50  dstaddr=10.2.1.10  action=ACCEPT
```

**Outcome:** PERMITTED. DNS resolution succeeds. Both VPCs log ACCEPT entries.

---

## UC-03 — Production App Accesses Shared Services (Patch Management)

**Scenario:** Production EC2 (10.0.1.20) connects to the patch management server at `10.2.1.30:8530` (WSUS/SSM endpoint).

**Actors:** Production App EC2 (10.0.1.x), Shared Services Patch Server (10.2.1.30)

### Step Flow

```
Step 1: Prod EC2 initiates TCP SYN to 10.2.1.30:8530

Step 2: Prod VPC workload-rt: 0.0.0.0/0 → TGW
        Packet arrives at TGW on prod attachment

Step 3: TGW looks up prod attachment → association: prod-rt
        Route lookup in prod-rt for 10.2.1.30

Step 4: prod-rt lookup
        ┌─────────────────────────────────────────────────────────┐
        │  10.2.0.0/16   → shared-svc-attachment (propagated) ← MATCH │
        └──────────────────────────────────────────────────────────┘
        Next hop: shared-svc-attachment

Step 5: Packet delivered to shared services VPC → patch server at 10.2.1.30

Step 6: Response returns via:
        shared-svc VPC → TGW (shared-services-rt) → 10.0.0.0/16
        → prod-attachment → prod VPC → 10.0.1.20

        Note: prod CIDR (10.0.0.0/16) is propagated into shared-services-rt
              so the return path exists.
```

**Outcome:** PERMITTED. Same symmetric return path as UC-02 but sourced from production.

---

## UC-04 — Production Workload Accesses the Internet

**Scenario:** Production EC2 (10.0.1.20) fetches a TLS certificate from `ocsp.pki.goog` (203.x.x.x).

**Actors:** Production EC2, NAT Gateway (networking VPC), Internet

### Step Flow

```
Step 1: Prod EC2 → 203.x.x.x:443
        Prod VPC workload-rt: 0.0.0.0/0 → TGW

Step 2: TGW → prod attachment → prod-rt lookup
        0.0.0.0/0 → networking-attachment (static route) ← MATCH
        (no more-specific route for 203.x.x.x)

Step 3: TGW forwards to networking-attachment
        Packet arrives at networking VPC TGW attachment subnet (10.3.100.x)

Step 4: Networking VPC TGW subnet route table (tgw-rt-us-east-1a)
        0.0.0.0/0 → nat-gw-us-east-1a

Step 5: NAT Gateway processes packet
        Source NAT: replaces src 10.0.1.20 with EIP (e.g., 18.x.x.x)
        Maintains connection tracking entry:
          EIP:srcport → 10.0.1.20:srcport (for return translation)

Step 6: NAT GW → public subnet
        Public RT: 0.0.0.0/0 → IGW
        Packet sent to internet via IGW

Step 7: Internet responds to 18.x.x.x (NAT GW EIP)

Step 8: IGW → public subnet → NAT GW (connection tracking)
        NAT GW performs DNAT: 18.x.x.x → 10.0.1.20

Step 9: NAT GW → public subnet route table
        10.0.0.0/8 → TGW (return route in public RT)
        Packet forwarded to TGW

Step 10: TGW receives packet on networking-attachment
         Association: egress-rt
         Route lookup in egress-rt for 10.0.1.20

Step 11: egress-rt lookup
         10.0.0.0/16 → prod-attachment (propagated) ← MATCH
         (more-specific /16 overrides the /8 blackhole)

Step 12: Packet delivered to prod VPC → 10.0.1.20 ✓

Step 13: Flow logs written on both VPCs
         prod VPC:        src=10.0.1.20  dst=203.x.x.x  action=ACCEPT
         networking VPC:  src=10.0.1.20  dst=203.x.x.x  action=ACCEPT
```

**Outcome:** PERMITTED. All egress exits from a single NAT GW EIP — observable, auditable, filterable.

---

## UC-05 — Dev Workload Accesses the Internet

Identical flow to UC-04 but source is `10.1.x.x` and TGW uses `nonprod-rt` for the initial lookup. Return path uses dev-attachment propagation in egress-rt.

---

## UC-06 — Production Attempts to Reach Dev Workload

**Scenario:** Misconfigured CI/CD pipeline running in production accidentally tries to reach a dev API at `10.1.1.80:8080`.

### Step Flow

```
Step 1: Prod EC2 → 10.1.1.80:8080

Step 2: Prod VPC workload-rt: 0.0.0.0/0 → TGW

Step 3: TGW → prod-attachment → prod-rt lookup for 10.1.1.80
        ┌─────────────────────────────────────────────────────────┐
        │  10.0.0.0/16   → prod-attachment (propagated)           │
        │  10.2.0.0/16   → shared-svc-attachment (propagated)     │
        │  10.3.0.0/16   → networking-attachment (propagated)     │
        │  0.0.0.0/0     → networking-attachment (static)         │
        │  10.1.0.0/16   → BLACKHOLE (static)          ← MATCH    │
        └──────────────────────────────────────────────────────────┘
        Packet dropped — blackhole

Step 4: REJECT logged in production VPC flow logs
        srcaddr=10.0.1.x  dstaddr=10.1.1.80  dstport=8080  action=REJECT
```

**Outcome:** DENIED. Bidirectional isolation confirmed.

---

## UC-07 — Initial Deployment Process

**Actor:** Platform Engineer with AWS credentials and Terraform access.

### Steps

```
Step 1: PREREQUISITES
        □ AWS CLI configured (aws sts get-caller-identity succeeds)
        □ IAM role with: ec2:*, s3:*, kms:*, logs:*, iam:CreateServiceLinkedRole
        □ Terraform >= 1.5.0 installed
        □ Git repository cloned (or Lab2 directory present)

Step 2: CONFIGURE VARIABLES
        cd /Users/krimo/Lab2
        cp terraform.tfvars.example terraform.tfvars
        # Edit terraform.tfvars:
        #   prefix = "lab2-healthcare"
        #   aws_region = "us-east-1"
        #   availability_zones = ["us-east-1a", "us-east-1b"]

Step 3: INITIALIZE
        terraform init
        # Downloads hashicorp/aws ~> 5.0 provider
        # Initializes local backend (state in terraform.tfstate)

Step 4: VALIDATE
        terraform validate
        # Checks HCL syntax and module interface contracts
        # Expected: "Success! The configuration is valid."

Step 5: PLAN (REVIEW)
        terraform plan -out=tfplan
        # Review:
        #   ~100 resources to create
        #   Transit Gateway + 5 route tables
        #   4 VPCs + subnets
        #   TGW attachments, associations, propagations
        #   Static routes + blackhole routes
        #   S3 bucket + KMS key + lifecycle
        # Confirm no unexpected destroys (first apply: all creates)

Step 6: APPLY
        terraform apply tfplan
        # Duration: ~5-8 minutes
        # TGW creation: ~3 min
        # NAT Gateway: ~2 min
        # S3 + KMS: immediate

Step 7: VERIFY OUTPUTS
        terraform output
        # Expected outputs:
        #   tgw_id                  = "tgw-0abc..."
        #   production_vpc_id       = "vpc-0..."
        #   dev_vpc_id              = "vpc-0..."
        #   nat_public_ips          = { "us-east-1a" = "18.x.x.x" }
        #   flow_logs_bucket_name   = "lab2-healthcare-vpc-flow-logs-123456789"

Step 8: VALIDATE SEGMENTATION
        # Launch test EC2 in dev workload subnet (10.1.1.x)
        # Launch test EC2 in production workload subnet (10.0.1.x)
        # Run test cases TC-01 through TC-08 from LLD §10
```

---

## UC-08 — Add a New Spoke VPC

**Scenario:** A QA environment needs to be added to the segmented network. It should behave identically to dev (isolated from prod, can reach shared services and internet).

**Actor:** Platform Engineer

### Steps

```
Step 1: PLAN CIDR ALLOCATION
        Choose non-overlapping CIDR: 10.4.0.0/16 (next available /16)
        Segment: nonproduction (same RT as dev)

Step 2: ADD MODULE CALL IN main.tf

        module "qa_vpc" {
          source = "./modules/spoke_vpc"

          name        = "${var.prefix}-qa"
          environment = "qa"
          segment     = "nonproduction"
          vpc_cidr    = "10.4.0.0/16"
          tgw_id      = module.transit_gateway.tgw_id

          # Same RT as dev → same isolation policy
          associate_route_table_id = module.transit_gateway.rt_nonproduction_id

          propagate_to_route_table_ids = [
            module.transit_gateway.rt_nonproduction_id,
            module.transit_gateway.rt_shared_services_id,
            module.transit_gateway.rt_egress_id,
          ]

          workload_subnets = [
            { cidr = "10.4.1.0/24", az = var.availability_zones[0] },
            { cidr = "10.4.2.0/24", az = var.availability_zones[1] },
          ]
          database_subnets = []
          tgw_subnets = [
            { cidr = "10.4.100.0/28", az = var.availability_zones[0] },
            { cidr = "10.4.100.16/28", az = var.availability_zones[1] },
          ]

          flow_log_bucket_arn = module.flow_logs.bucket_arn
          tags                = local.common_tags
        }

Step 3: ADD EGRESS STATIC ROUTE (already covered by nonprod_default_egress)
        No new static route needed — the QA attachment will be propagated
        into nonprod-rt which already has 0.0.0.0/0 → networking-attachment

Step 4: ADD BLACKHOLE FOR NEW CIDR IN prod-rt (if desired for defense-in-depth)

        resource "aws_ec2_transit_gateway_route" "prod_blackhole_qa" {
          destination_cidr_block         = "10.4.0.0/16"
          blackhole                      = true
          transit_gateway_route_table_id = module.transit_gateway.rt_production_id
        }

Step 5: PLAN AND APPLY
        terraform plan   # Review: new VPC + subnets + attachment + propagations
        terraform apply

Step 6: VERIFY
        # QA VPC EC2 → prod DB: TIMEOUT (REJECT in flow logs)
        # QA VPC EC2 → shared svc: CONNECT
        # QA VPC EC2 → internet: CONNECT (via NAT)
```

**Change lead time:** ~10 minutes (mostly TGW attachment creation). No changes to existing VPCs required.

---

## UC-09 — Break-Glass: Emergency Dev→Prod Access

**Scenario:** A P0 incident requires a developer to directly query the production EHR database for forensic diagnosis. The CISO approves a time-bound exception.

**Prerequisites:** Incident ticket opened, CISO written approval, change window declared.

### Steps

```
Step 1: OPEN CHANGE TICKET
        Document: incident ID, approver, time window, specific CIDRs/ports,
        rollback plan.

Step 2: ADD TEMPORARY VARIABLE TO terraform.tfvars
        break_glass_enabled = true
        break_glass_src_cidr = "10.1.0.0/16"  # dev VPC
        break_glass_dst_cidr = "10.0.0.0/16"  # prod VPC

Step 3: ADD CONDITIONAL RESOURCE IN main.tf
        variable "break_glass_enabled" {
          type    = bool
          default = false
        }

        resource "aws_ec2_transit_gateway_route" "break_glass" {
          count = var.break_glass_enabled ? 1 : 0

          # Remove the blackhole — add a forwarding route
          destination_cidr_block         = "10.0.0.0/16"
          transit_gateway_attachment_id  = module.production_vpc.tgw_attachment_id
          transit_gateway_route_table_id = module.transit_gateway.rt_nonproduction_id
        }

        NOTE: The blackhole resource (nonprod_blackhole_prod) must be
        removed or set count=0 when break_glass_enabled=true. Otherwise
        the blackhole takes precedence (same prefix, static routes —
        blackhole wins over forwarding in TGW when both are the same length).

Step 4: APPLY WITH APPROVAL
        terraform plan                   # Review: remove blackhole, add route
        terraform apply -var="break_glass_enabled=true"

Step 5: EXECUTE MAINTENANCE
        Developer connects via bastions/SSM — never direct access
        All traffic logged in flow logs (action=ACCEPT from 10.1.x.x to 10.0.x.x)
        Strict time limit enforced by change ticket

Step 6: REVOKE — IMMEDIATE ROLLBACK
        terraform apply -var="break_glass_enabled=false"
        # Restores blackhole, removes forwarding route
        # Segmentation restored to baseline

Step 7: EVIDENCE COLLECTION
        Pull flow logs for the break-glass window (UC-11)
        Attach to incident ticket as audit evidence
        Close change ticket
```

**Critical:** Step 6 must happen before the change window closes. Set a calendar reminder.

---

## UC-10 — Security Investigation: Confirm Cross-Segment Attempt

**Scenario:** SOC alert fires for unusual EC2 behavior in the dev VPC. Investigate whether it attempted to reach production.

**Actor:** Security Analyst

### Steps

```
Step 1: IDENTIFY TIME WINDOW
        Alert time: 2026-04-10 14:32 UTC
        Investigation window: 14:00–15:00 UTC (1-hour window)

Step 2: IDENTIFY DEV EC2 IP
        From alert: instance i-0abc123, private IP 10.1.1.50

Step 3: QUERY FLOW LOGS IN S3 VIA ATHENA

        -- Create Athena table if not exists
        CREATE EXTERNAL TABLE IF NOT EXISTS vpc_flow_logs (
          version        INT,
          account_id     STRING,
          interface_id   STRING,
          srcaddr        STRING,
          dstaddr        STRING,
          srcport        INT,
          dstport        INT,
          protocol       INT,
          packets        BIGINT,
          bytes          BIGINT,
          start          BIGINT,
          end_time       BIGINT,
          action         STRING,
          log_status     STRING
        )
        PARTITIONED BY (year STRING, month STRING, day STRING, hour STRING)
        STORED AS PARQUET
        LOCATION 's3://{bucket}/vpc-flow-logs/dev/'
        TBLPROPERTIES ('projection.enabled'='true', ...);

        -- Query: did 10.1.1.50 attempt to reach production CIDR?
        SELECT
          srcaddr, dstaddr, dstport, protocol,
          action, packets, bytes,
          from_unixtime(start) AS event_time
        FROM vpc_flow_logs
        WHERE year='2026' AND month='04' AND day='10' AND hour='14'
          AND srcaddr = '10.1.1.50'
          AND dstaddr LIKE '10.0.%'
        ORDER BY start ASC;

Step 4: INTERPRET RESULTS

        If action=REJECT:
          → Confirmed attempted lateral movement
          → TGW blocked it — no production impact
          → Evidence of attempted breach (HIPAA §164.308(a)(6)(ii) incident response)

        If action=ACCEPT:
          → Break-glass was active OR misconfiguration
          → Escalate immediately — check for break_glass_enabled in Terraform state

Step 5: EXPAND QUERY — FULL DESTINATION SWEEP
        -- What else did 10.1.1.50 try to reach?
        SELECT dstaddr, dstport, action, COUNT(*) as attempts
        FROM vpc_flow_logs
        WHERE year='2026' AND month='04' AND day='10'
          AND srcaddr = '10.1.1.50'
          AND action = 'REJECT'
        GROUP BY dstaddr, dstport, action
        ORDER BY attempts DESC;

Step 6: DOCUMENT FINDINGS
        Export query results to CSV
        Note: flow log S3 path, Athena query, time window, result
        Attach to incident ticket
```

---

## UC-11 — Compliance Audit: Produce HIPAA Flow Log Evidence

**Scenario:** Annual HIPAA audit. Auditor asks: "Provide evidence that PHI production systems are network-isolated from non-production environments."

**Actor:** Compliance Officer / Platform Engineer

### Steps

```
Step 1: TERRAFORM STATE AS POLICY EVIDENCE
        terraform show -json | jq '
          .values.root_module.resources[]
          | select(.type == "aws_ec2_transit_gateway_route")
          | {type, name, values: {
              destination: .values.destination_cidr_block,
              blackhole: .values.blackhole,
              route_table: .values.transit_gateway_route_table_id
            }}'

        This produces machine-readable evidence of:
        - prod-rt has blackhole for 10.1.0.0/16
        - nonprod-rt has blackhole for 10.0.0.0/16
        - No static forwarding route from dev to prod

Step 2: PROPAGATION MATRIX EVIDENCE
        terraform show -json | jq '
          .values.root_module.child_modules[].resources[]
          | select(.type == "aws_ec2_transit_gateway_route_table_propagation")
          | {attachment: .values.transit_gateway_attachment_id,
             route_table: .values.transit_gateway_route_table_id}'

        Produces: complete list of all propagations — maps to the
        propagation matrix in LLD §3. Auditor can verify dev is absent
        from prod-rt and prod is absent from nonprod-rt.

Step 3: FLOW LOG RETENTION EVIDENCE
        aws s3api get-bucket-lifecycle-configuration \
          --bucket $(terraform output -raw flow_logs_bucket_name)

        Confirms: 7-year retention (2557 days expiration) → HIPAA §164.316(b)(2)

Step 4: ENCRYPTION EVIDENCE
        aws s3api get-bucket-encryption \
          --bucket $(terraform output -raw flow_logs_bucket_name)

        Confirms: SSE-KMS with CMK → HIPAA §164.312(a)(2)(iv)

Step 5: FLOW LOG QUERY — 90-DAY DENIED TRAFFIC SUMMARY
        -- Aggregate all denied cross-segment traffic (last 90 days)
        SELECT
          DATE_FORMAT(from_unixtime(start), '%Y-%m-%d') AS date,
          srcaddr,
          dstaddr,
          dstport,
          action,
          COUNT(*) AS flow_count,
          SUM(packets) AS total_packets
        FROM vpc_flow_logs
        WHERE action = 'REJECT'
          AND srcaddr LIKE '10.1.%'   -- from dev
          AND dstaddr LIKE '10.0.%'   -- toward production
        GROUP BY 1,2,3,4,5
        ORDER BY date DESC;

        Zero ACCEPT rows with src=10.1.x.x and dst=10.0.x.x = compliance pass.
        All REJECT rows = evidence of enforcement working as designed.

Step 6: EXPORT EVIDENCE PACKAGE
        □ terraform show output (propagation matrix + blackhole routes)
        □ S3 lifecycle configuration JSON
        □ S3 encryption configuration JSON
        □ Athena query results CSV (denied traffic summary)
        □ KMS key rotation enabled confirmation
        □ Architecture diagram from docs/Architecture_Diagram.md
        □ This LLD document (LAB2-LLD-001)
```

---

## Process: Infrastructure Change Management

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    CHANGE MANAGEMENT PROCESS                            │
│                                                                         │
│  1. PROPOSE      Developer opens PR with Terraform changes               │
│       │          Description: what changed, why, blast radius            │
│       ▼                                                                  │
│  2. PLAN         CI runs: terraform plan -out=tfplan                     │
│       │          PR shows plan diff (added/changed/destroyed resources)  │
│       ▼                                                                  │
│  3. REVIEW       Security Engineer reviews:                              │
│       │          □ No new propagations into prod-rt from non-prod        │
│       │          □ No blackhole removals without break-glass approval    │
│       │          □ No new peerings bypassing TGW                         │
│       ▼                                                                  │
│  4. APPROVE      Two approvals required for prod-rt changes              │
│       │          One approval sufficient for new spoke additions         │
│       ▼                                                                  │
│  5. APPLY        terraform apply (CI/CD or manual in change window)      │
│       │          State committed to remote backend (S3 + DynamoDB lock)  │
│       ▼                                                                  │
│  6. VERIFY       Automated test suite runs TCs from LLD §10              │
│       │          Flow log query confirms no unexpected ACCEPT entries     │
│       ▼                                                                  │
│  7. DOCUMENT     Ticket closed with: apply output, test results          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Process: Incident Response — Network Isolation Breach

```
┌─────────────────────────────────────────────────────────────────────────┐
│              INCIDENT RESPONSE — SUSPECTED SEGMENTATION BYPASS          │
│                                                                         │
│  DETECT         GuardDuty / CloudWatch alert OR SOC manual detection    │
│     │                                                                   │
│     ▼                                                                   │
│  SCOPE          Query flow logs (UC-10 steps 1-5)                       │
│     │           Was traffic ACCEPT or REJECT?                           │
│     │                                                                   │
│     ├── REJECT ──→  CONTAIN (no action on network — already blocked)    │
│     │                Investigate source instance (quarantine SG)        │
│     │                Investigate how attacker reached dev segment        │
│     │                                                                   │
│     └── ACCEPT ──→  CRITICAL — segmentation bypassed                   │
│                     Step 1: Immediately re-apply Terraform baseline      │
│                       terraform apply (restores blackholes/propagations)│
│                     Step 2: Revoke all credentials for affected accounts │
│                     Step 3: Snapshot EBS volumes (forensic preservation) │
│                     Step 4: Notify CISO, Legal, Compliance              │
│                     Step 5: HIPAA breach assessment (§164.402)          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Process: Environment Tear-Down

```
Step 1: CONFIRM INTENT
        This is destructive and irreversible for flow log data
        unless S3 versioning preserves objects.

        Confirm:
        □ flow_log_force_destroy_bucket = true (set in terraform.tfvars)
        □ All flow logs backed up if required for active compliance period

Step 2: REMOVE DEPENDENT RESOURCES FIRST
        EC2 instances in VPC subnets must be terminated before
        terraform destroy (TGW cannot detach from VPCs with active ENIs)

Step 3: DESTROY
        terraform destroy
        # Duration: ~10 minutes
        # TGW detaches + deletes: ~5 min
        # NAT GW release: ~2 min
        # S3 bucket (force_destroy): immediate

Step 4: VERIFY
        aws ec2 describe-transit-gateways --region us-east-1
        # No TGWs with Project=Lab2-TGW-Segmentation tag should exist

        aws s3 ls | grep lab2-healthcare
        # Bucket should be absent
```
