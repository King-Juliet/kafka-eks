module "karpenter" {
  source = "../karpenter"

  cluster_name  = local.cluster_name
  region        = var.region
  chart_version = var.karpenter_chart_version
  node_selector = local.system_node_selector
  tolerations   = local.system_tolerations

  ami_alias            = var.ami_alias
  associate_public_ip  = local.nodes_in_public_subnets
  node_root_volume_gib = var.node_root_volume_gib

  node_pools = {
    general = {
      instance_types = var.general_instance_types
      cpu_limit      = var.general_cpu_limit
    }
    "kafka-controllers" = {
      instance_types = var.controller_instance_types
      cpu_limit      = var.controller_cpu_limit
    }
    "kafka-brokers" = {
      instance_types = var.broker_instance_types
      cpu_limit      = var.broker_cpu_limit
    }
  }

  tags = local.tags
}