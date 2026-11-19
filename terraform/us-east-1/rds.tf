# PostgreSQL the consumers write to. Reachable only from the ETL instances and the runner (migrations).
module "rds" {
  source = "../rds"

  name                = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnet_ids
  kms_key_arn         = module.kms.key_arns["rds"]
  engine_version      = var.db_engine_version
  instance_class      = var.db_instance_class
  multi_az            = var.db_multi_az
  deletion_protection = var.db_deletion_protection
  tags                = local.tags

  client_security_group_ids = {
    etl_clients = aws_security_group.etl_clients.id
    runner      = module.runner.security_group_id
    eks_nodes   = module.eks.node_security_group_id # ARC runner pods run the migration after ARC takes over
  }
}