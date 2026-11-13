terraform {
  required_version = ">= 1.10.0" # S3 native state locking (use_lockfile) needs 1.10+

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.59" # floor from the old EKS module; arguments checked against the provider docs of 2026-11-10
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3" # v3 syntax: kubernetes = { ... } is an attribute, not a block
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12" # used by the external-secrets module (a short wait for its webhooks)
    }
  }
}