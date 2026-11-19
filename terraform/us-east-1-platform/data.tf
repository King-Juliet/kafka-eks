# Everything this layer needs to know about layer 1 comes from its outputs.
data "terraform_remote_state" "layer1" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.layer1_state_key
    region = var.region
  }
}

# A login for your private registry (valid 12 hours, far longer than one apply). The Helm provider uses it to pull the
# Karpenter charts through the ECR cache (providers.tf).
data "aws_ecr_authorization_token" "this" {}