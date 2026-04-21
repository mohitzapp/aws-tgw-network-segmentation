###############################################################################
# Spoke VPC Module
# Reusable pattern for production, dev, and shared services VPCs.
# Each spoke has:
#   - Workload subnets (app / services tier)
#   - Optional database subnets (production EHR databases)
#   - TGW attachment subnets (/28, dedicated to TGW ENIs)
#   - TGW attachment + explicit association + propagations
#   - VPC flow logs → central S3 bucket
#   - Default security group locked to deny-all (no accidental open rules)
###############################################################################

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name        = var.name
    Environment = var.environment
    Segment     = var.segment
  })
}

###############################################################################
# Lock down the default security group — deny all ingress and egress.
# This prevents accidental resource deployments from inheriting open rules.
###############################################################################

resource "aws_default_security_group" "deny_all" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name    = "${var.name}-default-sg-deny-all"
    Purpose = "deny-all-baseline"
  })
}

###############################################################################
# Workload Subnets (app/service tier)
###############################################################################

resource "aws_subnet" "workload" {
  for_each = { for s in var.workload_subnets : s.az => s }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-workload-${each.value.az}"
    Tier = "workload"
  })
}

###############################################################################
# Database Subnets (optional — production EHR tier)
###############################################################################

resource "aws_subnet" "database" {
  for_each = { for s in var.database_subnets : s.az => s }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-db-${each.value.az}"
    Tier = "database"
  })
}

###############################################################################
# TGW Attachment Subnets (/28 per AZ — dedicated to TGW ENIs only)
# Best practice: isolate TGW ENIs from workload subnets so security group
# rules on workload ENIs do not affect TGW traffic processing.
###############################################################################

resource "aws_subnet" "tgw" {
  for_each = { for s in var.tgw_subnets : s.az => s }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-tgw-${each.value.az}"
    Tier = "tgw-attachment"
  })
}

###############################################################################
# TGW Attachment
###############################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  vpc_id             = aws_vpc.this.id
  transit_gateway_id = var.tgw_id
  subnet_ids         = [for s in aws_subnet.tgw : s.id]

  # Disable defaults — explicit association and propagation below
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  dns_support = "enable"

  tags = merge(var.tags, {
    Name        = "${var.name}-tgw-attachment"
    Environment = var.environment
    Segment     = var.segment
  })
}

###############################################################################
# TGW Route Table Association
# Associates this attachment with the segment-specific route table.
# Traffic arriving at the TGW from this VPC is looked up in this RT.
###############################################################################

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.associate_route_table_id
}

###############################################################################
# TGW Route Table Propagations
# Propagates this VPC's CIDR into the specified route tables, making this VPC
# reachable from other attachments associated with those route tables.
# The propagation matrix is the primary segmentation enforcement mechanism.
###############################################################################

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = var.propagate_to_route_table_ids

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = each.value
}

###############################################################################
# Workload Route Table
# Default route → TGW (internet via centralized NAT; spoke-to-spoke via TGW)
###############################################################################

resource "aws_route_table" "workload" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-workload-rt"
    Tier = "workload"
  })
}

resource "aws_route" "workload_default" {
  route_table_id         = aws_route_table.workload.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "workload" {
  for_each = aws_subnet.workload

  subnet_id      = each.value.id
  route_table_id = aws_route_table.workload.id
}

###############################################################################
# Database Route Table (created only when database_subnets is non-empty)
###############################################################################

resource "aws_route_table" "database" {
  count = length(var.database_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-db-rt"
    Tier = "database"
  })
}

resource "aws_route" "database_default" {
  count = length(var.database_subnets) > 0 ? 1 : 0

  route_table_id         = aws_route_table.database[0].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "database" {
  for_each = aws_subnet.database

  subnet_id      = each.value.id
  route_table_id = aws_route_table.database[0].id
}

###############################################################################
# TGW Subnet Route Table (local only — TGW ENIs do not initiate traffic)
###############################################################################

resource "aws_route_table" "tgw" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-tgw-rt"
    Tier = "tgw-attachment"
  })
}

resource "aws_route_table_association" "tgw" {
  for_each = aws_subnet.tgw

  subnet_id      = each.value.id
  route_table_id = aws_route_table.tgw.id
}

###############################################################################
# VPC Flow Logs → Central S3 Bucket
# Parquet format with Hive-compatible partitions for Athena cost efficiency.
# Prefix: vpc-flow-logs/{environment}/ for easy per-segment querying.
###############################################################################

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${var.flow_log_bucket_arn}/vpc-flow-logs/${var.environment}/"

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = merge(var.tags, {
    Name = "${var.name}-flow-log"
  })
}
