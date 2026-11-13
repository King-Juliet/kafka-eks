module "kms" {
  source = "../kms"

  name_prefix = var.cluster_name
  keys = {
    "eks-secrets" = "Envelope encryption of Kubernetes Secrets (${var.cluster_name})"
    "ebs-kafka"   = "Kafka data volumes (EBS gp3) for ${var.cluster_name}"
  }
  tags = local.tags
}