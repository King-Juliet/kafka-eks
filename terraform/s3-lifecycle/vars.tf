variable "bucket_name" {
  description = "The bucket the rules apply to (it must already exist; pass the s3-bucket module's bucket_name)."
  type        = string
}

variable "rules" {
  description = <<-EOT
    Lifecycle rules, by name. Leave empty ({}) and nothing is created. Each rule needs at least one of:
      expiration_days                  delete current objects this many days after they were created
      noncurrent_version_days          delete old versions this many days after they were replaced (needs versioning on the bucket)
      abort_incomplete_multipart_days  clean up uploads that were started and never finished
    prefix limits a rule to objects whose key starts with it (default: the whole bucket).
  EOT
  type = map(object({
    prefix                          = optional(string, "")
    expiration_days                 = optional(number)
    noncurrent_version_days         = optional(number)
    abort_incomplete_multipart_days = optional(number)
  }))
  default = {}

  validation {
    condition = alltrue([
      for r in values(var.rules) :
      r.expiration_days != null || r.noncurrent_version_days != null || r.abort_incomplete_multipart_days != null
    ])
    error_message = "Every rule needs at least one of expiration_days, noncurrent_version_days, abort_incomplete_multipart_days."
  }
}