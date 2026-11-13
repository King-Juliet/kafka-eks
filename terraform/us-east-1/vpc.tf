module "vpc" {
  source = "../vpc"

  name               = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  azs                = local.azs
  node_subnet_tier   = var.node_subnet_tier
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  tags               = local.tags
}