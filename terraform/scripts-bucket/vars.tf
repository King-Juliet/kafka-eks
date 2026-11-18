variable "bucket_name" {
  description = "Globally unique bucket name. The region folder builds it from the cluster name, account id and region."
  type        = string
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete the bucket even when it holds objects. Keep false: it holds the release history."
  type        = bool
  default     = false
}

variable "noncurrent_version_days" {
  description = "ASSUMPTION: 90 days. How long overwritten/deleted object versions are kept (rollback window for a bad upload)."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}