###############################################################################
# Transit Gateway
# Creates the TGW and all 5 route tables. Route table associations and
# propagations are handled in the spoke/networking VPC modules, which receive
# the route table IDs as inputs.
###############################################################################

resource "aws_ec2_transit_gateway" "this" {
  description = var.description

  amazon_side_asn = var.amazon_side_asn

  # Disable defaults — every attachment gets explicit association/propagation
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  dns_support       = "enable"
  vpn_ecmp_support  = "enable"
  multicast_support = "disable"

  tags = merge(var.tags, {
    Name = var.name
  })
}

###############################################################################
# Route Tables
# prod-rt     → production workloads only
# nonprod-rt  → dev/test workloads; no access to prod CIDRs
# shared-rt   → shared services (AD, DNS, patch); reachable by prod and nonprod
# egress-rt   → networking VPC (centralized NAT egress); never routes between spokes
# inspection-rt → reserved for future inline NFW / GWLB inspection path
###############################################################################

resource "aws_ec2_transit_gateway_route_table" "production" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(var.tags, {
    Name        = "${var.name}-prod-rt"
    Segment     = "production"
    Description = "Production workloads - isolated from non-production"
  })
}

resource "aws_ec2_transit_gateway_route_table" "nonproduction" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(var.tags, {
    Name        = "${var.name}-nonprod-rt"
    Segment     = "nonproduction"
    Description = "Dev/test workloads - isolated from production"
  })
}

resource "aws_ec2_transit_gateway_route_table" "shared_services" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(var.tags, {
    Name        = "${var.name}-shared-services-rt"
    Segment     = "shared-services"
    Description = "AD, DNS, patch - selectively reachable by prod and nonprod"
  })
}

resource "aws_ec2_transit_gateway_route_table" "egress" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(var.tags, {
    Name        = "${var.name}-egress-rt"
    Segment     = "egress"
    Description = "Networking VPC attachment - centralized NAT egress only"
  })
}

resource "aws_ec2_transit_gateway_route_table" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(var.tags, {
    Name        = "${var.name}-inspection-rt"
    Segment     = "inspection"
    Description = "Reserved for NFW/GWLB inline inspection path"
  })
}
