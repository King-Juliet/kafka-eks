locals {
  l1 = data.terraform_remote_state.layer1.outputs

  cluster_name = local.l1.cluster_name
  vpc_id       = local.l1.vpc_id

  tags = merge(
    {
      Project   = local.cluster_name
      ManagedBy = "terraform"
    },
    var.extra_tags
  )

  # One switch drives every "public IP or not" setting (Karpenter nodes). Read from layer 1 so the two never disagree.
  nodes_in_public_subnets = local.l1.node_subnet_tier == "public"

  # Where charts and images come from: the ECR pull-through cache built in layer 1 (terraform/us-east-1/ecr.tf).
  # Keys: ecr-public, quay, ghcr. Each value is <account>.dkr.ecr.<region>.amazonaws.com/<key>.
  ecr = local.l1.ecr_cache_paths

  # Platform controllers live on the tainted system node group.
  system_node_selector = { workload = "system" }
  system_tolerations   = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
}