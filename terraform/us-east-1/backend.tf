# Remote state in S3 with native locking (no DynamoDB table). Backend blocks cannot use variables,
# so edit this file once: put your bucket name in `bucket` (RUNBOOK step 3 does it with one sed).
# `region` is the region of the BUCKET and of this folder.
terraform {
  backend "s3" {
    bucket       = "juliet-terraform-state"
    key          = "eks-kafka/us-east-1/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}