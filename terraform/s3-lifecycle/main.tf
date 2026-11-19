# Lifecycle rules for an S3 bucket: delete objects or old versions after N days, clean up unfinished uploads.
# It does not create the bucket (see the s3-bucket module). A bucket has ONE lifecycle configuration, so put every
# rule for a bucket in this module's `rules`, not in two calls. No rules, no resource.

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count = length(var.rules) == 0 ? 0 : 1

  bucket = var.bucket_name

  dynamic "rule" {
    for_each = var.rules

    content {
      id     = rule.key
      status = "Enabled"

      filter {
        prefix = rule.value.prefix == "" ? null : rule.value.prefix
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days == null ? [] : [rule.value.expiration_days]

        content {
          days = expiration.value
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_days == null ? [] : [rule.value.noncurrent_version_days]

        content {
          noncurrent_days = noncurrent_version_expiration.value
        }
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_days == null ? [] : [rule.value.abort_incomplete_multipart_days]

        content {
          days_after_initiation = abort_incomplete_multipart_upload.value
        }
      }
    }
  }
}