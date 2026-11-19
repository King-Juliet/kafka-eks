module "aws_load_balancer_controller" {
  source = "../aws-load-balancer-controller"

  cluster_name  = local.cluster_name
  region        = var.region
  vpc_id        = local.vpc_id
  chart_version = var.lbc_chart_version
  node_selector = local.system_node_selector
  tolerations   = local.system_tolerations
  tags          = local.tags

  # The controller image comes from your ECR copy of public.ecr.aws (layer 1). The chart comes from AWS's Helm repository.
  public_ecr_mirror = local.ecr["ecr-public"]

  # The LB controller registers a webhook on every new Service. Install it only after Karpenter
  # (which creates a Service) is finished, so the two never race. It also needs the Gateway API
  # types to exist before it starts, or it leaves its Gateway support off.
  depends_on = [module.karpenter, module.gateway_api]
}