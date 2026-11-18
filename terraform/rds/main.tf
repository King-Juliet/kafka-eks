# PostgreSQL for the ETL consumers. Private, encrypted, Multi-AZ, SSL enforced.
#
# Passwords: RDS generates the MASTER password, stores it in Secrets Manager and rotates it itself, so it
# never touches Terraform state. The ETL does not use it (a rotation would break the running consumers);
# the migration job creates a separate application user, see scripts/db_migrate.py.

data "aws_partition" "current" {}

locals {
  engine_major = split(".", var.engine_version)[0]
}

# Enhanced monitoring (OS-level metrics every `monitoring_interval` seconds) needs a role RDS can assume.
resource "aws_iam_role" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name = "${var.name}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-etl"
  subnet_ids = var.subnet_ids

  tags = var.tags
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-etl-db-"
  description = "ETL PostgreSQL: 5432 from named client security groups only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-etl-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  for_each = var.client_security_group_ids

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from ${each.key}"
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-etl-"
  family      = "postgres${local.engine_major}"
  description = "ETL PostgreSQL: SSL required"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-etl"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.master_username

  # RDS creates and rotates the master password in Secrets Manager. No password in code or state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  allocated_storage     = var.allocated_storage_gib
  max_allocated_storage = var.max_allocated_storage_gib > 0 ? var.max_allocated_storage_gib : null
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  port                   = 5432

  backup_retention_period = var.backup_retention_days
  backup_window           = "02:00-03:00"
  maintenance_window      = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = false

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-etl-final"

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null

  # Lets people and tools sign in with short-lived IAM tokens instead of a password. The ETL itself uses its own
  # database user and password (scripts/db_migrate.py); this only makes the other option available.
  iam_database_authentication_enabled = true

  tags = var.tags
}