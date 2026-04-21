output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "tgw_attachment_id" {
  description = "Transit Gateway VPC attachment ID — used in root main.tf for static TGW routes"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

output "workload_subnet_ids" {
  description = "Workload subnet IDs (app/service tier)"
  value       = [for s in aws_subnet.workload : s.id]
}

output "workload_subnet_cidrs" {
  description = "Workload subnet CIDR blocks"
  value       = [for s in aws_subnet.workload : s.cidr_block]
}

output "database_subnet_ids" {
  description = "Database subnet IDs (empty if no database subnets configured)"
  value       = [for s in aws_subnet.database : s.id]
}

output "database_subnet_cidrs" {
  description = "Database subnet CIDR blocks"
  value       = [for s in aws_subnet.database : s.cidr_block]
}

output "tgw_subnet_ids" {
  description = "TGW attachment subnet IDs"
  value       = [for s in aws_subnet.tgw : s.id]
}

output "workload_route_table_id" {
  description = "Route table ID for workload subnets"
  value       = aws_route_table.workload.id
}

output "database_route_table_id" {
  description = "Route table ID for database subnets (null if no database subnets)"
  value       = length(aws_route_table.database) > 0 ? aws_route_table.database[0].id : null
}

output "flow_log_id" {
  description = "VPC flow log resource ID (empty string if flow logging disabled)"
  value       = length(aws_flow_log.this) > 0 ? aws_flow_log.this[0].id : ""
}
