# This layer only talks to AWS. Everything that needs the Kubernetes API (Karpenter, the load balancer
# controller, External Secrets, ...) lives in ../us-east-1-platform, which runs on an in-VPC runner because
# the API is private.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}