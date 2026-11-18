data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Created by ../bootstrap (an empty shell; its value, a GitHub token, is typed in once by a human).
data "aws_secretsmanager_secret" "runner_auth" {
  name = var.runner_auth_secret_name
}