###############################################################################
# Global
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Naming prefix applied to every resource (e.g. 'lab2-healthcare')"
  type        = string
}

variable "owner" {
  description = "Team or individual owning this infrastructure (used in default tags)"
  type        = string
  default     = "platform-engineering"
}

variable "cost_center" {
  description = "Cost center code for billing tags"
  type        = string
  default     = "infra-labs"
}

###############################################################################
# Transit Gateway
###############################################################################

variable "tgw_amazon_side_asn" {
  description = "Private ASN for the TGW BGP session (must be unique per AWS account)"
  type        = number
  default     = 64512
}

###############################################################################
# VPC CIDRs
###############################################################################

variable "production_vpc_cidr" {
  description = "CIDR block for the production VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "dev_vpc_cidr" {
  description = "CIDR block for the development VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "shared_services_vpc_cidr" {
  description = "CIDR block for the shared services VPC (AD, DNS, patch)"
  type        = string
  default     = "10.2.0.0/16"
}

variable "networking_vpc_cidr" {
  description = "CIDR block for the centralized egress networking VPC"
  type        = string
  default     = "10.3.0.0/16"
}

###############################################################################
# Availability Zones
###############################################################################

variable "availability_zones" {
  description = "List of AZs to deploy subnets into. Two AZs is sufficient for the lab."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

###############################################################################
# Flow Logs
###############################################################################

variable "flow_log_force_destroy_bucket" {
  description = "Allow Terraform to destroy the flow logs S3 bucket even if it has objects. Set to false in production."
  type        = bool
  default     = true
}

###############################################################################
# NAT Gateway
###############################################################################

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ. Saves cost in lab environments."
  type        = bool
  default     = true
}

###############################################################################
# Common Tags
###############################################################################

variable "extra_tags" {
  description = "Additional tags merged into every resource. Use for compliance labels (HIPAA, PCI-DSS)."
  type        = map(string)
  default     = {}
}
