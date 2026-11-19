# Where CD uploads the ETL code for the producer and consumer ASGs to copy. One folder per Git commit:
#
#   releases/<git-sha>/producer/...      the producer script
#   releases/<git-sha>/consumers/...     the three consumer scripts
#   releases/<git-sha>/topics/...        topic admin scripts
#   releases/<git-sha>/ops/...           lag publisher
#   releases/<git-sha>/wheelhouse/...    Python packages (so instances need no internet to install them)
#
# The instances read the "current release" pointer from Secrets Manager (local.config_secret_names.clients_release),
# copy that folder and run it. Old releases stay (versioned bucket), so a rollback is just moving the pointer back.
# The generic modules are ../s3-bucket and ../s3-lifecycle; everything specific to this bucket is below.
locals {
  # Bucket names are global, so the account id and the region are part of the name.
  scripts_bucket_name = "${var.cluster_name}-etl-scripts-${data.aws_caller_identity.current.account_id}-${var.region}"
}

module "scripts_bucket" {
  source = "../s3-bucket"

  bucket_name        = local.scripts_bucket_name
  force_destroy      = false # it holds the release history
  versioning_enabled = true  # an overwritten or deleted upload can be brought back

  # ASSUMPTION: S3-managed keys (SSE-S3), no kms_key_arn. A customer key would also need kms:Decrypt on every
  # instance role, and the code in this bucket is not secret (it is the same code that sits in Git).
  kms_key_arn = null

  tags = local.tags
}

# Lifecycle rules (the ../s3-lifecycle module). A bucket that needs none simply does not call it.
module "scripts_bucket_lifecycle" {
  source = "../s3-lifecycle"

  bucket_name = module.scripts_bucket.bucket_name

  rules = {
    clean-up = {
      noncurrent_version_days         = 90 # ASSUMPTION: long enough to notice a bad upload and roll back
      abort_incomplete_multipart_days = 7
    }
  }

  # The versioning setting must exist before a rule about old versions is added.
  depends_on = [module.scripts_bucket]
}