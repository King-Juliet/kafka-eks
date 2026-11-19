# Block consumer (consumers/block_data_consumer.py). It scales on ITS OWN consumer group's lag (1 to 5 instances),
# independently of the other consumers. 5 is the ceiling because the topics have 5 partitions: more consumers would
# sit idle (module lag-scaling refuses a larger maximum).
locals {
  consumer_block = {
    name                           = "${var.cluster_name}-etl-consumer-block"
    kafka_user                     = "consumer-app"
    script                         = "consumers/block_data_consumer.py"
    lag_group_id                   = "bitcoin_block_consumer_group"
    instance_type                  = "t3.medium" # ASSUMPTION: not load-tested
    min_size                       = 1
    max_size                       = 5
    desired_size                   = 1
    refresh_min_healthy_percentage = 50
  }
}

resource "aws_cloudwatch_log_group" "consumer_block" {
  name              = "/${var.cluster_name}/etl/consumer-block"
  retention_in_days = local.etl_log_retention_days
  tags              = local.tags
}

# The common permissions plus its own Kafka password.
data "aws_iam_policy_document" "consumer_block" {
  source_policy_documents = [data.aws_iam_policy_document.etl_common.json]

  statement {
    sid       = "ReadOwnKafkaPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local.etl_secret_arn_prefix}/kafka/clients/${local.consumer_block.kafka_user}-*"]
  }
}

module "consumer_block_role" {
  source = "../ec2-role"

  name        = local.consumer_block.name
  policy_json = data.aws_iam_policy_document.consumer_block.json
  tags        = local.tags
}

module "consumer_block_asg" {
  source = "../asg"

  name                           = local.consumer_block.name
  image_id                       = data.aws_ssm_parameter.etl_al2023.value
  instance_type                  = local.consumer_block.instance_type
  subnet_ids                     = module.vpc.node_subnet_ids
  security_group_ids             = [aws_security_group.etl_clients.id]
  instance_profile_name          = module.consumer_block_role.instance_profile_name
  min_size                       = local.consumer_block.min_size
  max_size                       = local.consumer_block.max_size
  desired_size                   = local.consumer_block.desired_size
  refresh_min_healthy_percentage = local.consumer_block.refresh_min_healthy_percentage
  instance_tags                  = { EtlGroup = "consumer-block" }
  tags                           = local.tags

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", merge(local.etl_user_data_common, {
    group_key         = "consumer-block"
    kafka_user        = local.consumer_block.kafka_user
    script            = local.consumer_block.script
    run_lag_publisher = false
    log_group         = aws_cloudwatch_log_group.consumer_block.name
  }))

  # Outbound access (NAT route, VPC endpoints) must exist before the first instance boots.
  depends_on = [module.vpc, module.vpc_endpoints]
}

# Scale out and in on this consumer group's lag, and warn when the lag number stops arriving.
module "consumer_block_lag" {
  source = "../lag-scaling"

  name             = local.consumer_block.name
  asg_name         = module.consumer_block_asg.asg_name
  lag_group_id     = local.consumer_block.lag_group_id
  scaling_enabled  = local.consumer_block.max_size > local.consumer_block.min_size
  max_size         = local.consumer_block.max_size
  partition_count  = local.etl_partition_count
  metric_namespace = local.etl_metric_namespace
  alarm_actions    = local.etl_alarm_actions
  tags             = local.tags
}

resource "aws_cloudwatch_metric_alarm" "consumer_block_instances_down" {
  alarm_name          = "${local.consumer_block.name}-instances-down"
  alarm_description   = "Fewer than ${local.consumer_block.min_size} instance(s) of consumer-block are in service."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = module.consumer_block_asg.asg_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  threshold           = local.consumer_block.min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.etl_alarm_actions
  ok_actions    = local.etl_alarm_actions

  tags = local.tags
}