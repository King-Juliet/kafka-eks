locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = merge(
    {
      Project   = var.cluster_name
      ManagedBy = "terraform"
    },
    var.extra_tags
  )

  # The Kubernetes API is reached through a Session Manager tunnel on your Mac (RUNBOOK step 5), so Terraform's
  # Kubernetes and Helm providers talk to localhost. The API certificate does not list "localhost", so the
  # providers are told which name to check it against: the cluster's real endpoint name.
  api_tunnel_url  = "https://localhost:${var.api_tunnel_port}"
  api_server_name = trimprefix(module.eks.cluster_endpoint, "https://")

  # One switch drives every "public IP or not" setting (Karpenter nodes).
  nodes_in_public_subnets = var.node_subnet_tier == "public"

  # Platform controllers live on the tainted system node group.
  system_node_selector = { workload = "system" }
  system_tolerations   = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
}