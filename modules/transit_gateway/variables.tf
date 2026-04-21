variable "name" {
  description = "Name prefix for the Transit Gateway and route tables"
  type        = string
}

variable "description" {
  description = "Human-readable description for the Transit Gateway"
  type        = string
  default     = "Transit Gateway for network segmentation"
}

variable "amazon_side_asn" {
  description = "Private ASN for the Amazon side of the BGP session"
  type        = number
  default     = 64512
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
