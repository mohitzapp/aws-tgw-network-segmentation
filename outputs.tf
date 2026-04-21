###############################################################################
# Root Outputs
###############################################################################

# ─── Transit Gateway ──────────────────────────────────────────────────────────

output "tgw_id" {
  description = "Transit Gateway ID"
  value       = module.transit_gateway.tgw_id
}

output "tgw_route_table_ids" {
  description = "Map of segment name → TGW route table ID"
  value = {
    production      = module.transit_gateway.rt_production_id
    nonproduction   = module.transit_gateway.rt_nonproduction_id
    shared_services = module.transit_gateway.rt_shared_services_id
    egress          = module.transit_gateway.rt_egress_id
    inspection      = module.transit_gateway.rt_inspection_id
  }
}

# ─── VPC IDs ──────────────────────────────────────────────────────────────────

output "production_vpc_id" {
  description = "Production VPC ID"
  value       = module.production_vpc.vpc_id
}

output "dev_vpc_id" {
  description = "Dev VPC ID"
  value       = module.dev_vpc.vpc_id
}

output "shared_services_vpc_id" {
  description = "Shared Services VPC ID"
  value       = module.shared_services_vpc.vpc_id
}

output "networking_vpc_id" {
  description = "Networking (egress) VPC ID"
  value       = module.networking_vpc.vpc_id
}

# ─── TGW Attachment IDs ───────────────────────────────────────────────────────

output "tgw_attachment_ids" {
  description = "Map of VPC name → TGW attachment ID"
  value = {
    production      = module.production_vpc.tgw_attachment_id
    dev             = module.dev_vpc.tgw_attachment_id
    shared_services = module.shared_services_vpc.tgw_attachment_id
    networking      = module.networking_vpc.tgw_attachment_id
  }
}

# ─── Production Subnets ───────────────────────────────────────────────────────

output "production_workload_subnet_ids" {
  description = "Production workload subnet IDs (app tier)"
  value       = module.production_vpc.workload_subnet_ids
}

output "production_database_subnet_ids" {
  description = "Production database subnet IDs (EHR tier)"
  value       = module.production_vpc.database_subnet_ids
}

# ─── Dev Subnets ──────────────────────────────────────────────────────────────

output "dev_workload_subnet_ids" {
  description = "Dev workload subnet IDs"
  value       = module.dev_vpc.workload_subnet_ids
}

# ─── Shared Services Subnets ──────────────────────────────────────────────────

output "shared_services_workload_subnet_ids" {
  description = "Shared services subnet IDs (AD, DNS, patch)"
  value       = module.shared_services_vpc.workload_subnet_ids
}

# ─── Networking VPC ───────────────────────────────────────────────────────────

output "nat_public_ips" {
  description = "Map of AZ → NAT Gateway public IP (egress IPs to whitelist in downstream firewalls)"
  value       = module.networking_vpc.nat_public_ips
}

# ─── Flow Logs ────────────────────────────────────────────────────────────────

output "flow_logs_bucket_name" {
  description = "Central flow logs S3 bucket name"
  value       = module.flow_logs.bucket_name
}

output "flow_logs_bucket_arn" {
  description = "Central flow logs S3 bucket ARN"
  value       = module.flow_logs.bucket_arn
}

output "flow_logs_kms_key_arn" {
  description = "KMS key ARN used to encrypt flow logs"
  value       = module.flow_logs.kms_key_arn
}

# ─── Demo Athena Query Helper ─────────────────────────────────────────────────

output "athena_query_hint" {
  description = "S3 path prefix for querying denied traffic in the flow logs bucket"
  value       = "s3://${module.flow_logs.bucket_name}/vpc-flow-logs/"
}
