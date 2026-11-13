# EKS control plane, system node group and core add-ons (no Auto Mode).
# The public API endpoint allows exactly one address: the bastion's Elastic IP (bastion.tf).
module "eks" {
  source = "../cluster"

  name                     = var.cluster_name
  kubernetes_version       = var.kubernetes_version
  vpc_id                   = module.vpc.vpc_id
  vpc_cidr                 = var.vpc_cidr
  subnet_ids               = module.vpc.node_subnet_ids    # worker nodes (public in phase 1)
  control_plane_subnet_ids = module.vpc.private_subnet_ids # control-plane ENIs (always private tier)
  api_allowed_cidrs        = ["0.0.0.0/0"]
  secrets_kms_key_arn      = module.kms.key_arns["eks-secrets"]
  ebs_kms_key_arn          = module.kms.key_arns["ebs-kafka"]
  admin_principal_arns     = var.admin_principal_arns
  system_instance_types    = var.system_instance_types
  log_retention_days       = var.log_retention_days
  enable_network_policy    = var.enable_network_policy
  deletion_protection      = var.deletion_protection
  tags                     = local.tags
}