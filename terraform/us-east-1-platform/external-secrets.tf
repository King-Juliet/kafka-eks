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

  # Charts and images from your ECR (the pull-through cache, layer 1). The External Secrets image comes from the ghcr copy.
  ghcr_mirror         = local.ecr["ghcr"]
  ecr_pull_policy_arn = local.l1.ecr_cache_pull_policy_arn

  # Argo CD pulls the Strimzi and ARC charts from your ECR too. External Secrets keeps a fresh ECR login in an Argo CD
  # repository Secret for each. These two paths must equal the repoURL of the apps in gitops/argocd/apps
  # (tests/test_ecr_wiring.py checks that they use the same registry paths).
  argocd_oci_repos = {
    strimzi = "${local.ecr["quay"]}/strimzi-helm"
    arc     = "${local.ecr["ghcr"]}/actions/actions-runner-controller-charts"
  }

  # ESO creates Services, so it waits for the LB controller's webhook to be ready. The argocd namespace must
  # exist before the chart's ExternalSecret (argocd-namespace.tf).
  depends_on = [module.aws_load_balancer_controller, kubernetes_namespace_v1.argocd]
}