variable "name" {
  description = "Name prefix for all resources (e.g. 'lab2-networking')"
  type        = string
}

variable "vpc_cidr" {
  description = "Primary CIDR block for the networking VPC (e.g. '10.3.0.0/16')"
  type        = string
}

variable "tgw_id" {
  description = "Transit Gateway ID to attach this VPC to"
  type        = string
}

variable "associate_route_table_id" {
  description = "TGW route table ID to associate the networking VPC attachment with (should be egress-rt)"
  type        = string
}

variable "propagate_to_route_table_ids" {
  description = "TGW route table IDs to propagate the networking VPC CIDR into"
  type        = list(string)
  default     = []
}

variable "public_subnets" {
  description = "Public subnets that host NAT Gateways. One per AZ."
  type = list(object({
    cidr = string
    az   = string
  }))
}

variable "tgw_subnets" {
  description = "Subnets dedicated to TGW attachment ENIs. Use /28 per AZ."
  type = list(object({
    cidr = string
    az   = string
  }))
}

variable "spoke_cidr_supernet" {
  description = "RFC1918 supernet covering all spoke VPC CIDRs. Added as a return route in the public subnet RT so NAT GW responses go back via TGW. Typically '10.0.0.0/8'."
  type        = string
  default     = "10.0.0.0/8"
}

variable "single_nat_gateway" {
  description = "Deploy a single NAT Gateway (cost-saving for labs). Set to false for HA production pattern (one NAT GW per AZ)."
  type        = bool
  default     = true
}

variable "flow_log_bucket_arn" {
  description = "ARN of the central S3 bucket for VPC flow logs. Set to empty string to disable."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags applied to all resources in this module"
  type        = map(string)
  default     = {}
}
