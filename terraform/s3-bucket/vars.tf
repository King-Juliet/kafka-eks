variable "bucket_name" {
  description = "Globally unique bucket name."
  type        = string
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete the bucket even when it holds objects. Keep false for anything you cannot recreate."
  type        = bool
  default     = false
}

variable "versioning_enabled" {
  description = "Keep old versions of overwritten or deleted objects (a rollback window). false = skip versioning altogether."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for encryption at rest. null = S3-managed keys (SSE-S3). With a key, every reader and writer also needs kms:Decrypt / kms:GenerateDataKey on it."
  type        = string
  default     = null
}

variable "extra_policy_json" {
  description = "Optional extra bucket policy statements (an IAM policy document JSON), merged with the built-in TLS-only rule. Use it to let another account or a role in."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}