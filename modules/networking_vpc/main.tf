###############################################################################
# Networking VPC — Centralized Egress
# This VPC lives in a dedicated "networking account" in a real org.
# It provides centralized internet egress for all spokes via NAT Gateway.
#
# Traffic flow (outbound):
#   Spoke → TGW → egress-rt → this VPC TGW attachment
#   → TGW subnet route table → NAT Gateway → IGW → internet
#
# Traffic flow (return):
#   internet → IGW → NAT Gateway → public subnet
#   → public subnet RT (10.0.0.0/8 → TGW) → TGW egress-rt
#   → propagated spoke CIDR → spoke attachment → spoke VPC
###############################################################################

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name    = var.name
    Purpose = "centralized-egress"
    Segment = "networking"
  })
}

resource "aws_default_security_group" "deny_all" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name    = "${var.name}-default-sg-deny-all"
    Purpose = "deny-all-baseline"
  })
}

###############################################################################
# Internet Gateway
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-igw"
  })
}

###############################################################################
# Public Subnets — host NAT Gateways
###############################################################################

resource "aws_subnet" "public" {
  for_each = { for s in var.public_subnets : s.az => s }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false # NAT GW gets EIP; no workloads here

  tags = merge(var.tags, {
    Name = "${var.name}-public-${each.value.az}"
    Tier = "public"
  })
}

###############################################################################
# TGW Attachment Subnets (/28 per AZ — dedicated to TGW ENIs)
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
# Elastic IPs for NAT Gateways
# var.single_nat_gateway=true  → one EIP in first AZ (lab cost saving)
# var.single_nat_gateway=false → one EIP per AZ (HA production pattern)
###############################################################################

locals {
  # AZs for which we create a NAT GW
  nat_azs = var.single_nat_gateway ? [keys({ for s in var.public_subnets : s.az => s })[0]] : [for s in var.public_subnets : s.az]
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat-eip-${each.key}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(var.tags, {
    Name = "${var.name}-nat-gw-${each.key}"
  })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Public Subnet Route Table
# 0.0.0.0/0 → IGW      (NAT GW sends internet traffic out)
# RFC1918 supernet → TGW  (return traffic from NAT GW back to spokes)
###############################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-public-rt"
    Tier = "public"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# Return path: NAT GW translated responses destined for spoke CIDRs go back via TGW
resource "aws_route" "public_spoke_return" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = var.spoke_cidr_supernet
  transit_gateway_id     = var.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# TGW Subnet Route Tables (one per AZ for AZ-affinity with NAT GW)
# 0.0.0.0/0 → NAT GW in same AZ (forward spoke internet traffic)
# RFC1918 → local (return spoke-to-spoke traffic resolved by TGW itself)
###############################################################################

resource "aws_route_table" "tgw" {
  for_each = aws_subnet.tgw

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-tgw-rt-${each.key}"
    Tier = "tgw-attachment"
  })
}

# Default route from TGW subnet → NAT GW (AZ-affinity: use same-AZ NAT GW, fall back to first AZ)
resource "aws_route" "tgw_to_nat" {
  for_each = aws_route_table.tgw

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"

  # Use same-AZ NAT GW if available (HA mode), else use the single NAT GW
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[local.nat_azs[0]].id : aws_nat_gateway.this[each.key].id
}

resource "aws_route_table_association" "tgw" {
  for_each = aws_subnet.tgw

  subnet_id      = each.value.id
  route_table_id = aws_route_table.tgw[each.key].id
}

###############################################################################
# TGW Attachment
###############################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  vpc_id             = aws_vpc.this.id
  transit_gateway_id = var.tgw_id
  subnet_ids         = [for s in aws_subnet.tgw : s.id]

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  dns_support = "enable"

  tags = merge(var.tags, {
    Name    = "${var.name}-tgw-attachment"
    Purpose = "centralized-egress"
    Segment = "networking"
  })
}

###############################################################################
# TGW Route Table Association (egress-rt)
###############################################################################

resource "aws_ec2_transit_gateway_route_table_association" "this" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = var.associate_route_table_id
}

###############################################################################
# TGW Route Table Propagations
# Networking VPC propagates its CIDR into all specified route tables so that
# spokes can receive return traffic from the NAT Gateway.
###############################################################################

resource "aws_ec2_transit_gateway_route_table_propagation" "this" {
  for_each = toset(var.propagate_to_route_table_ids)

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = each.value
}

###############################################################################
# VPC Flow Logs → Central S3 Bucket
###############################################################################

resource "aws_flow_log" "this" {
  count = var.flow_log_bucket_arn != "" ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${var.flow_log_bucket_arn}/vpc-flow-logs/networking/"

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = merge(var.tags, {
    Name = "${var.name}-flow-log"
  })
}
