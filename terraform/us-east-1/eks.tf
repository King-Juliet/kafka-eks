# EKS control plane, system node group and core add-ons (no Auto Mode).
# The API endpoint is PRIVATE: it answers only inside the VPC. Callers are the CI runners (runner.tf) and the
# in-cluster ARC runners (which are nodes, so the node security group already allows them).
module "eks" {
  source = "../cluster"

  name                     = var.cluster_name
  kubernetes_version       = var.kubernetes_version
  vpc_id                   = module.vpc.vpc_id
  vpc_cidr                 = var.vpc_cidr
  subnet_ids               = module.vpc.node_subnet_ids    # worker nodes (private)
  control_plane_subnet_ids = module.vpc.private_subnet_ids # control-plane ENIs (private)
  endpoint_public_access   = false
  bootstrap_creator_admin  = false # access is explicit: the deploy role and var.admin_principal_arns
  admin_principal_arns     = local.cluster_admins
  api_client_security_group_ids = {
    runner = module.runner.security_group_id
  }
  secrets_kms_key_arn   = module.kms.key_arns["eks-secrets"]
  ebs_kms_key_arn       = module.kms.key_arns["ebs-kafka"]
  system_instance_types = var.system_instance_types
  log_retention_days    = var.log_retention_days
  enable_network_policy = var.enable_network_policy
  deletion_protection   = var.deletion_protection
  tags                  = local.tags
}