# A private S3 bucket with the safe defaults: no public access, owner-enforced objects (no ACLs), encryption at rest,
# HTTPS only. Versioning is optional (versioning_enabled = false creates nothing). It knows nothing about what is stored
# in it. Lifecycle rules are NOT here: they are the s3-lifecycle module, which a caller adds only if it wants them.
# The caller decides the name, the encryption key and any extra access (see scripts-bucket.tf for an example).

resource "aws_s3_bucket" "this" {
  # checkov:skip=CKV2_AWS_61: lifecycle rules are the separate s3-lifecycle module, added by the caller; Checkov cannot follow that link across modules.
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Skipped when versioning_enabled = false: the bucket then keeps only the latest version of each object (the S3 default).
resource "aws_s3_bucket_versioning" "this" {
  count = var.versioning_enabled ? 1 : 0

  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

data "aws_iam_policy_document" "this" {
  source_policy_documents = var.extra_policy_json == null ? [] : [var.extra_policy_json]

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}