###############################################################################
# Lab 2 — Transit Gateway Network Segmentation
#
# Architecture:
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │                        Transit Gateway                              │
#   │  prod-rt │ nonprod-rt │ shared-services-rt │ egress-rt │ inspect-rt│
#   └────┬──────────┬──────────────┬─────────────────┬────────────────────┘
#        │          │              │                  │
#   Production   Dev VPC    Shared Services     Networking VPC
#    VPC (EHR)  (cannot    (AD, DNS — both       (NAT GW egress)
#   10.0.0.0/16  reach      segments reach)       10.3.0.0/16
#               prod!)      10.2.0.0/16
#   10.0.0.0/16 10.1.0.0/16
#
# Segmentation enforcement:
#   1. dev attachment does NOT propagate into prod-rt  → no route to prod
#   2. prod attachment does NOT propagate into nonprod-rt → no route to dev
#   3. Blackhole routes in prod-rt and nonprod-rt add defense-in-depth
#   4. shared-services propagates into BOTH → reachable by prod and dev
#   5. All spokes have 0.0.0.0/0 → networking attachment for internet egress
###############################################################################

locals {
  common_tags = merge(var.extra_tags, {
    Lab = "Lab2-TGW-Segmentation"
  })
}

###############################################################################
# 1. Central Flow Logs Infrastructure (simulated security account S3 bucket)
###############################################################################

module "flow_logs" {
  source = "./modules/flow_logs"

  prefix        = var.prefix
  force_destroy = var.flow_log_force_destroy_bucket
  tags          = local.common_tags
}

###############################################################################
# 2. Transit Gateway + 5 Route Tables
###############################################################################

module "transit_gateway" {
  source = "./modules/transit_gateway"

  name            = "${var.prefix}-tgw"
  description     = "Healthcare org TGW — blast radius segmentation for HIPAA/PCI-DSS"
  amazon_side_asn = var.tgw_amazon_side_asn
  tags            = local.common_tags
}

###############################################################################
# 3. Networking VPC — Centralized Egress
###############################################################################

module "networking_vpc" {
  source = "./modules/networking_vpc"

  name               = "${var.prefix}-networking"
  vpc_cidr           = var.networking_vpc_cidr
  tgw_id             = module.transit_gateway.tgw_id
  single_nat_gateway = var.single_nat_gateway

  # Associates with egress-rt — the dedicated route table for this VPC
  associate_route_table_id = module.transit_gateway.rt_egress_id

  # Networking VPC propagates into egress-rt only.
  # Spokes will propagate into egress-rt so return traffic works.
  propagate_to_route_table_ids = [module.transit_gateway.rt_egress_id]

  public_subnets = [
    { cidr = "10.3.1.0/24", az = var.availability_zones[0] },
    { cidr = "10.3.2.0/24", az = var.availability_zones[1] },
  ]

  tgw_subnets = [
    { cidr = "10.3.100.0/28", az = var.availability_zones[0] },
    { cidr = "10.3.100.16/28", az = var.availability_zones[1] },
  ]

  spoke_cidr_supernet = "10.0.0.0/8"
  flow_log_bucket_arn = module.flow_logs.bucket_arn
  tags                = local.common_tags
}

###############################################################################
# 4. Production Spoke VPC (EHR workloads + databases)
#
# Propagation matrix:
#   prod attachment → prod-rt         (self — prod can route to prod)
#   prod attachment → shared-services-rt (prod can reach AD/DNS/patch)
#   prod attachment → egress-rt       (return path: NAT GW → prod)
#
# NOT propagated into nonprod-rt → dev VPC has NO route to 10.0.0.0/16
###############################################################################

module "production_vpc" {
  source = "./modules/spoke_vpc"

  name        = "${var.prefix}-production"
  environment = "production"
  segment     = "production"
  vpc_cidr    = var.production_vpc_cidr
  tgw_id      = module.transit_gateway.tgw_id

  associate_route_table_id = module.transit_gateway.rt_production_id

  propagate_to_route_table_ids = [
    module.transit_gateway.rt_production_id,      # prod routes known in prod-rt
    module.transit_gateway.rt_shared_services_id, # shared services can route back to prod
    module.transit_gateway.rt_egress_id,          # NAT GW return traffic can reach prod
  ]

  workload_subnets = [
    { cidr = "10.0.1.0/24", az = var.availability_zones[0] },
    { cidr = "10.0.2.0/24", az = var.availability_zones[1] },
  ]

  # EHR database tier — production only
  database_subnets = [
    { cidr = "10.0.10.0/24", az = var.availability_zones[0] },
    { cidr = "10.0.11.0/24", az = var.availability_zones[1] },
  ]

  tgw_subnets = [
    { cidr = "10.0.100.0/28", az = var.availability_zones[0] },
    { cidr = "10.0.100.16/28", az = var.availability_zones[1] },
  ]

  flow_log_bucket_arn = module.flow_logs.bucket_arn
  tags                = local.common_tags
}

###############################################################################
# 5. Dev Spoke VPC
#
# Propagation matrix:
#   dev attachment → nonprod-rt       (self)
#   dev attachment → shared-services-rt (dev can reach AD/DNS/patch)
#   dev attachment → egress-rt        (return path)
#
# NOT propagated into prod-rt → prod VPC has NO route to 10.1.0.0/16
###############################################################################

module "dev_vpc" {
  source = "./modules/spoke_vpc"

  name        = "${var.prefix}-dev"
  environment = "dev"
  segment     = "nonproduction"
  vpc_cidr    = var.dev_vpc_cidr
  tgw_id      = module.transit_gateway.tgw_id

  associate_route_table_id = module.transit_gateway.rt_nonproduction_id

  propagate_to_route_table_ids = [
    module.transit_gateway.rt_nonproduction_id,   # dev routes known in nonprod-rt
    module.transit_gateway.rt_shared_services_id, # shared services can route back to dev
    module.transit_gateway.rt_egress_id,          # NAT GW return traffic can reach dev
  ]

  workload_subnets = [
    { cidr = "10.1.1.0/24", az = var.availability_zones[0] },
    { cidr = "10.1.2.0/24", az = var.availability_zones[1] },
  ]

  # No separate database tier in dev — workload subnets handle all tiers
  database_subnets = []

  tgw_subnets = [
    { cidr = "10.1.100.0/28", az = var.availability_zones[0] },
    { cidr = "10.1.100.16/28", az = var.availability_zones[1] },
  ]

  flow_log_bucket_arn = module.flow_logs.bucket_arn
  tags                = local.common_tags
}

###############################################################################
# 6. Shared Services Spoke VPC (Active Directory, DNS, patch management)
#
# Propagation matrix:
#   shared attachment → prod-rt           (prod can route to shared services)
#   shared attachment → nonprod-rt        (dev can route to shared services)
#   shared attachment → shared-services-rt (self)
#   shared attachment → egress-rt         (return path)
#
# Shared services propagates into BOTH prod-rt AND nonprod-rt — this is the
# "selective reachability" pattern: neither prod nor dev can reach each other,
# but both can reach shared services.
###############################################################################

module "shared_services_vpc" {
  source = "./modules/spoke_vpc"

  name        = "${var.prefix}-shared-services"
  environment = "shared-services"
  segment     = "shared-services"
  vpc_cidr    = var.shared_services_vpc_cidr
  tgw_id      = module.transit_gateway.tgw_id

  associate_route_table_id = module.transit_gateway.rt_shared_services_id

  propagate_to_route_table_ids = [
    module.transit_gateway.rt_production_id,      # prod can reach shared services
    module.transit_gateway.rt_nonproduction_id,   # dev can reach shared services
    module.transit_gateway.rt_shared_services_id, # self
    module.transit_gateway.rt_egress_id,          # NAT GW return traffic
  ]

  workload_subnets = [
    { cidr = "10.2.1.0/24", az = var.availability_zones[0] },
    { cidr = "10.2.2.0/24", az = var.availability_zones[1] },
  ]

  database_subnets = []

  tgw_subnets = [
    { cidr = "10.2.100.0/28", az = var.availability_zones[0] },
    { cidr = "10.2.100.16/28", az = var.availability_zones[1] },
  ]

  flow_log_bucket_arn = module.flow_logs.bucket_arn
  tags                = local.common_tags
}

###############################################################################
# 7. TGW Static Routes
#
# These live in the root module because they cross module boundaries:
# they reference route table IDs (from transit_gateway module) AND
# attachment IDs (from spoke/networking modules).
###############################################################################

# ─── Default egress routes (0.0.0.0/0 → networking attachment) ──────────────
# All spoke route tables get a default route pointing to the networking VPC
# attachment. Internet-bound traffic exits through the centralized NAT Gateway.

resource "aws_ec2_transit_gateway_route" "prod_default_egress" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = module.networking_vpc.tgw_attachment_id
  transit_gateway_route_table_id = module.transit_gateway.rt_production_id
}

resource "aws_ec2_transit_gateway_route" "nonprod_default_egress" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = module.networking_vpc.tgw_attachment_id
  transit_gateway_route_table_id = module.transit_gateway.rt_nonproduction_id
}

resource "aws_ec2_transit_gateway_route" "shared_services_default_egress" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = module.networking_vpc.tgw_attachment_id
  transit_gateway_route_table_id = module.transit_gateway.rt_shared_services_id
}

# ─── Blackhole routes (defense-in-depth on top of missing propagations) ──────
# Even though dev does not propagate into prod-rt (and vice versa), explicit
# blackhole routes ensure any accidentally injected static route or future
# misconfiguration cannot create a cross-segment path.

# prod-rt: explicitly black-hole dev CIDR
resource "aws_ec2_transit_gateway_route" "prod_blackhole_dev" {
  destination_cidr_block         = var.dev_vpc_cidr
  blackhole                      = true
  transit_gateway_route_table_id = module.transit_gateway.rt_production_id
}

# nonprod-rt: explicitly black-hole prod CIDR
resource "aws_ec2_transit_gateway_route" "nonprod_blackhole_prod" {
  destination_cidr_block         = var.production_vpc_cidr
  blackhole                      = true
  transit_gateway_route_table_id = module.transit_gateway.rt_nonproduction_id
}

# egress-rt: prevent the networking VPC from being used as a pivot between spokes.
# Spoke routes in egress-rt are propagated by spoke attachments (for return traffic),
# but we add RFC1918 blackholes for inter-spoke routes that should never traverse egress.
# These more-specific propagated routes (e.g., 10.0.0.0/16) override the /8 blackhole,
# so only legitimate return traffic is permitted.

resource "aws_ec2_transit_gateway_route" "egress_blackhole_rfc1918_10" {
  destination_cidr_block         = "10.0.0.0/8"
  blackhole                      = true
  transit_gateway_route_table_id = module.transit_gateway.rt_egress_id

  # More-specific propagated routes (10.0.0.0/16, 10.1.0.0/16, etc.) from
  # spoke attachments will override this /8 blackhole for legitimate return traffic.
  # The /8 catch-all drops any non-spoke RFC1918 traffic that hits egress-rt.
  depends_on = [
    module.production_vpc,
    module.dev_vpc,
    module.shared_services_vpc,
  ]
}
