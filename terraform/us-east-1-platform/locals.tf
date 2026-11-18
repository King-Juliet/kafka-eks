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

  # Platform controllers live on the tainted system node group.
  system_node_selector = { workload = "system" }
  system_tolerations   = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
}