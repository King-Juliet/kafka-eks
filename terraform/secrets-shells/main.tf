# Creates the secret CONTAINERS only. Values are put in by hand (console / CLI) so they never
# land in Terraform state. External Secrets Operator reads them from here.
#
# Encryption: AWS-managed key aws/secretsmanager (ASSUMPTION - a CMK is listed in RUNBOOK.txt, NOT PART OF THIS BUILD).

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secret_names

  name                    = each.value
  description             = "Value set manually. Consumed by External Secrets Operator."
  recovery_window_in_days = var.recovery_window_in_days

  tags = var.tags
}