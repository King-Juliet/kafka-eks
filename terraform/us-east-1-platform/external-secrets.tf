module "external_secrets" {
  source = "../external-secrets"

  cluster_name               = local.cluster_name
  region                     = var.region
  chart_version              = var.eso_chart_version
  argocd_repo_secret_enabled = var.argocd_repo_secret_enabled
  node_selector              = local.system_node_selector
  tolerations                = local.system_tolerations
  tags                       = local.tags

  # /github/ lets ESO read the runner registration token (ARC). Read-only: PushSecret stays /kafka/ only.
  secret_name_prefixes = ["/argocd/", "/kafka/", "/github/"]

  # ESO creates Services, so it waits for the LB controller's webhook to be ready. The argocd namespace must
  # exist before the chart's ExternalSecret (argocd-namespace.tf).
  depends_on = [module.aws_load_balancer_controller, kubernetes_namespace_v1.argocd]
}