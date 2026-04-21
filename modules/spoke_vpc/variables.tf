variable "name" {
  description = "Name for this VPC and all child resources (e.g. 'lab2-production')"
  type        = string
}

variable "environment" {
  description = "Environment label used in tags and flow log prefix (e.g. 'production', 'dev', 'shared-services')"
  type        = string
}

variable "segment" {
  description = "TGW segment this VPC belongs to. Used in tags (e.g. 'production', 'nonproduction', 'shared-services')"
  type        = string
}

variable "vpc_cidr" {
  description = "Primary CIDR block for the VPC (e.g. '10.0.0.0/16')"
  type        = string
}

variable "tgw_id" {
  description = "Transit Gateway ID to attach this VPC to"
  type        = string
}

variable "associate_route_table_id" {
  description = "TGW route table ID to associate this attachment with. Determines which RT the TGW uses to look up destinations for traffic sourced from this VPC."
  type        = string
}

variable "propagate_to_route_table_ids" {
  description = "List of TGW route table IDs to propagate this VPC's CIDR into. Controls which other segments can reach this VPC."
  type        = list(string)
}

variable "workload_subnets" {
  description = "Workload (app/service tier) subnets. One per AZ."
  type = list(object({
    cidr = string
    az   = string
  }))
}

variable "database_subnets" {
  description = "Database tier subnets. One per AZ. Leave empty for non-production VPCs."
  type = list(object({
    cidr = string
    az   = string
  }))
  default = []
}

variable "tgw_subnets" {
  description = "Subnets dedicated to TGW attachment ENIs. Use /28 per AZ (11 usable IPs — sufficient for TGW ENIs)."
  type = list(object({
    cidr = string
    az   = string
  }))
}

variable "flow_log_bucket_arn" {
  description = "ARN of the central S3 bucket for VPC flow logs. Set to empty string to disable flow logging."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags applied to all resources in this module"
  type        = map(string)
  default     = {}
}
