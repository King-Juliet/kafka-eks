provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Kubernetes and Helm talk to the cluster that eks.tf creates in this same run.
# The API only accepts the bastion's Elastic IP, so they connect to a Session Manager tunnel on this machine
# (RUNBOOK step 5, `terraform output api_tunnel_command`). The tunnel must be open for every plan, apply and
# destroy once the cluster exists.
# Tokens are short-lived and come from the AWS CLI (no static credentials, nothing stored in state).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

# Helm provider 3.x takes the connection as an attribute (kubernetes = { ... }), not a nested block.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}