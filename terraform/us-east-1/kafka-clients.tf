# Producer (exactly 1) and consumer Auto Scaling Groups. Created together with everything else: the instances
# find the Kafka address and the code release through SSM parameters that CD fills in later, so there is no
# "set a variable after Kafka is up" step any more.
module "kafka_clients" {
  source = "../kafka-clients"

  name_prefix         = var.cluster_name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.node_subnet_ids
  scripts_bucket_name = module.scripts_bucket.bucket_name
  scripts_bucket_arn  = module.scripts_bucket.bucket_arn
  db_app_secret_arn   = module.db_app_secret.secret_arns[var.db_app_secret_name]
  alarm_topic_arn     = var.alarm_topic_arn
  groups              = var.etl_groups
  tags                = local.tags
}