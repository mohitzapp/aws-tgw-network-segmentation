output "tgw_id" {
  description = "Transit Gateway ID"
  value       = aws_ec2_transit_gateway.this.id
}

output "tgw_arn" {
  description = "Transit Gateway ARN"
  value       = aws_ec2_transit_gateway.this.arn
}

output "tgw_owner_id" {
  description = "AWS account that owns the Transit Gateway"
  value       = aws_ec2_transit_gateway.this.owner_id
}

# Route Table IDs — passed into spoke and networking VPC modules
output "rt_production_id" {
  description = "Route table ID for production segment"
  value       = aws_ec2_transit_gateway_route_table.production.id
}

output "rt_nonproduction_id" {
  description = "Route table ID for non-production (dev/test) segment"
  value       = aws_ec2_transit_gateway_route_table.nonproduction.id
}

output "rt_shared_services_id" {
  description = "Route table ID for shared services segment"
  value       = aws_ec2_transit_gateway_route_table.shared_services.id
}

output "rt_egress_id" {
  description = "Route table ID for centralized egress (networking VPC)"
  value       = aws_ec2_transit_gateway_route_table.egress.id
}

output "rt_inspection_id" {
  description = "Route table ID reserved for inline inspection"
  value       = aws_ec2_transit_gateway_route_table.inspection.id
}
