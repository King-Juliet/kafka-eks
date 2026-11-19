provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# The Kubernetes API is private, so this layer only works from a machine inside the VPC: the bootstrap runner or
# an in-cluster ARC runner (see .github/workflows/cd.yml). Tokens are short-lived and come from the AWS CLI using
# whatever credentials the job has (the deploy role): no static credentials, nothing stored in state.
provider "kubernetes" {
  host                   = local.l1.cluster_endpoint
  cluster_ca_certificate = base64decode(local.l1.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
  }
}

# Helm provider 3.x takes the connection as an attribute (kubernetes = { ... }), not a nested block.
provider "helm" {
  # Charts are pulled from your own ECR (the pull-through cache from layer 1), which needs a login.
  registries = [{
    url      = "oci://${local.l1.ecr_registry_host}"
    username = data.aws_ecr_authorization_token.this.user_name
    password = data.aws_ecr_authorization_token.this.password
  }]

  kubernetes = {
    host                   = local.l1.cluster_endpoint
    cluster_ca_certificate = base64decode(local.l1.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region]
    }
  }
}