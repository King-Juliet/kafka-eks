# Empty container for the ETL's own database user. scripts/db_migrate.py (run by CD) creates the user and writes
# its credentials here, so the value never passes through Terraform state.
module "db_app_secret" {
  source = "../secrets-shells"

  secret_names = [var.db_app_secret_name]
  tags         = local.tags
}