variable "prefix" {
  description = "Naming prefix for all resources (e.g. 'lab2-healthcare')"
  type        = string
}

variable "source_account_ids" {
  description = "AWS account IDs allowed to deliver flow logs to this bucket. Defaults to the current account if empty."
  type        = list(string)
  default     = []
}

variable "force_destroy" {
  description = "Allow destroying the bucket even if it contains objects. Set to false in production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
