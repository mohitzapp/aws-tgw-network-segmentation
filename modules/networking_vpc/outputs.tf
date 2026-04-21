output "vpc_id" {
  description = "Networking VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Networking VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "tgw_attachment_id" {
  description = "Transit Gateway VPC attachment ID — used in root main.tf for egress static routes in spoke RTs"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "Map of AZ → NAT Gateway ID"
  value       = { for az, ngw in aws_nat_gateway.this : az => ngw.id }
}

output "nat_public_ips" {
  description = "Map of AZ → NAT Gateway public (Elastic) IP address"
  value       = { for az, eip in aws_eip.nat : az => eip.public_ip }
}

output "public_subnet_ids" {
  description = "Public subnet IDs (host NAT Gateways)"
  value       = [for s in aws_subnet.public : s.id]
}

output "tgw_subnet_ids" {
  description = "TGW attachment subnet IDs"
  value       = [for s in aws_subnet.tgw : s.id]
}

output "flow_log_id" {
  description = "VPC flow log resource ID (empty string if flow logging disabled)"
  value       = length(aws_flow_log.this) > 0 ? aws_flow_log.this[0].id : ""
}
