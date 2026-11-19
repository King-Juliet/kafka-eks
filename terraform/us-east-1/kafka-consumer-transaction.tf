# Transaction consumer (consumers/transaction_data_consumer.py). Pinned to ONE instance: it pairs block and transaction
# messages in memory, so splitting its partitions across machines would break the pairing. Because min = max there are
# no scaling policies (module lag-scaling still gives it the "lag metric missing" alarm). To let it scale one day,
# fix the pairing first, then raise max_size.
locals {
  consumer_transaction = {
    name          = "${var.cluster_name}-etl-consumer-transaction"
    kafka_user    = "consumer-app"
    script        = "consumers/transaction_data_consumer.py"
    lag_group_id  = "bitcoin_consumer_group"
    instance_type = "t3.medium" # ASSUMPTION: not load-tested
    min_size      = 1
    max_size      = 1
    desired_size  = 1
    # Replace it by stopping the old instance BEFORE starting the new one: it must never run twice at once.
    refresh_min_healthy_percentage = 0
  }
}

resource "aws_cloudwatch_log_group" "consumer_transaction" {
  name              = "/${var.cluster_name}/etl/consumer-transaction"
  retention_in_days = local.etl_log_retention_days
  tags              = local.tags
}

# The common permissions plus its own Kafka password.
data "aws_iam_policy_document" "consumer_transaction" {
  source_policy_documents = [data.aws_iam_policy_document.etl_common.json]

  statement {
    sid       = "ReadOwnKafkaPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local.etl_secret_arn_prefix}/kafka/clients/${local.consumer_transaction.kafka_user}-*"]
  }
}

module "consumer_transaction_role" {
  source = "../ec2-role"

  name        = local.consumer_transaction.name
  policy_json = data.aws_iam_policy_document.consumer_transaction.json
  tags        = local.tags
}

module "consumer_transaction_asg" {
  source = "../asg"

  name                           = local.consumer_transaction.name
  image_id                       = data.aws_ssm_parameter.etl_al2023.value
  instance_type                  = local.consumer_transaction.instance_type
  subnet_ids                     = module.vpc.node_subnet_ids
  security_group_ids             = [aws_security_group.etl_clients.id]
  instance_profile_name          = module.consumer_transaction_role.instance_profile_name
  min_size                       = local.consumer_transaction.min_size
  max_size                       = local.consumer_transaction.max_size
  desired_size                   = local.consumer_transaction.desired_size
  refresh_min_healthy_percentage = local.consumer_transaction.refresh_min_healthy_percentage
  instance_tags                  = { EtlGroup = "consumer-transaction" }
  tags                           = local.tags

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", merge(local.etl_user_data_common, {
    group_key         = "consumer-transaction"
    kafka_user        = local.consumer_transaction.kafka_user
    script            = local.consumer_transaction.script
    run_lag_publisher = false
    log_group         = aws_cloudwatch_log_group.consumer_transaction.name
  }))

  # Outbound access (NAT route, VPC endpoints) must exist before the first instance boots.
  depends_on = [module.vpc, module.vpc_endpoints]
}

# No scaling (min = max), but a warning when this consumer group's lag number stops arriving.
module "consumer_transaction_lag" {
  source = "../lag-scaling"

  name             = local.consumer_transaction.name
  asg_name         = module.consumer_transaction_asg.asg_name
  lag_group_id     = local.consumer_transaction.lag_group_id
  scaling_enabled  = local.consumer_transaction.max_size > local.consumer_transaction.min_size
  max_size         = local.consumer_transaction.max_size
  partition_count  = local.etl_partition_count
  metric_namespace = local.etl_metric_namespace
  alarm_actions    = local.etl_alarm_actions
  tags             = local.tags
}

resource "aws_cloudwatch_metric_alarm" "consumer_transaction_instances_down" {
  alarm_name          = "${local.consumer_transaction.name}-instances-down"
  alarm_description   = "Fewer than ${local.consumer_transaction.min_size} instance(s) of consumer-transaction are in service."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = module.consumer_transaction_asg.asg_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  threshold           = local.consumer_transaction.min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.etl_alarm_actions
  ok_actions    = local.etl_alarm_actions

  tags = local.tags
}