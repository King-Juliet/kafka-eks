module "external_secrets" {
  source = "../external-secrets"

  cluster_name               = module.eks.cluster_name
  region                     = var.region
  chart_version              = var.eso_chart_version
  argocd_repo_secret_enabled = var.argocd_repo_secret_enabled
  node_selector              = local.system_node_selector
  tolerations                = local.system_tolerations
  tags                       = local.tags

  # ESO creates Services, so it waits for the LB controller's webhook to be ready.
  depends_on = [module.aws_load_balancer_controller]
}