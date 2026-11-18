locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = merge(
    {
      Project   = var.cluster_name
      ManagedBy = "terraform"
    },
    var.extra_tags
  )

  # Roles created by ../bootstrap. They are referenced by NAME so this folder works without reading that state.
  gh_cd_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.ci_name_prefix}-gh-cd"

  # Who is cluster-admin: the deploy role (it runs the platform layer) plus any humans listed in var.admin_principal_arns.
  cluster_admins = distinct(concat([local.gh_cd_role_arn], var.admin_principal_arns))

  # Scripts bucket names are global, so account id and region are part of the name.
  scripts_bucket_name = "${var.cluster_name}-etl-scripts-${data.aws_caller_identity.current.account_id}-${var.region}"
}