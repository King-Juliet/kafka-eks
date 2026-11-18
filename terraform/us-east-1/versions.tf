terraform {
  required_version = ">= 1.10.0" # S3 native state locking (use_lockfile) needs 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59" # floor from the old EKS module; arguments checked against the provider docs of 2026-11-10
    }
  }
}