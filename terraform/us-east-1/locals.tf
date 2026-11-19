locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = merge(
    {
      Project   = var.cluster_name
      ManagedBy = "terraform"
    },
    var.extra_tags
  )

  # Who is cluster-admin: the GitHub deploy role (it runs the platform layer) plus any humans listed in var.admin_principal_arns.
  cluster_admins = distinct(concat([var.deploy_role_arn], var.admin_principal_arns))
}