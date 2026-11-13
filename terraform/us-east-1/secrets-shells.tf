# Empty Secrets Manager entries (values are typed in by hand so they never reach Terraform state).
module "secrets_shells" {
  source = "../secrets-shells"

  secret_names = var.argocd_secret_names
  tags         = local.tags
}