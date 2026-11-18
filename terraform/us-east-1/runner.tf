# One small in-VPC GitHub runner for the very first run (and as a fallback). CD scales it to 0 once the
# in-cluster ARC runners are healthy. See ../runner.
module "runner" {
  source = "../runner"

  name            = var.cluster_name
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.node_subnet_ids
  github_repo     = var.github_repo
  auth_secret_arn = data.aws_secretsmanager_secret.runner_auth.arn
  instance_type   = var.runner_instance_type
  tags            = local.tags

  # Outbound access needs the NAT route to exist before the instance boots.
  depends_on = [module.vpc]
}