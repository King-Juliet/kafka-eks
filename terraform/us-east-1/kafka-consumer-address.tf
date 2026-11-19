# Address consumer (consumers/address_data_consumer.py). It scales on ITS OWN consumer group's lag (1 to 5 instances),
# independently of the other consumers. 5 is the ceiling because the topics have 5 partitions: more consumers would
# sit idle (module lag-scaling refuses a larger maximum).
locals {
  consumer_address = {
    name                           = "${var.cluster_name}-etl-consumer-address"
    kafka_user                     = "consumer-app"
    script                         = "consumers/address_data_consumer.py"
    lag_group_id                   = "bitcoin_address_consumer_group"
    instance_type                  = "t3.medium" # ASSUMPTION: not load-tested
    min_size                       = 1
    max_size                       = 5
    desired_size                   = 1
    refresh_min_healthy_percentage = 50
  }
}

resource "aws_cloudwatch_log_group" "consumer_address" {
  name              = "/${var.cluster_name}/etl/consumer-address"
  retention_in_days = local.etl_log_retention_days
  tags              = local.tags
}

# The common permissions plus its own Kafka password.
data "aws_iam_policy_document" "consumer_address" {
  source_policy_documents = [data.aws_iam_policy_document.etl_common.json]

  statement {
    sid       = "ReadOwnKafkaPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local.etl_secret_arn_prefix}/kafka/clients/${local.consumer_address.kafka_user}-*"]
  }
}

module "consumer_address_role" {
  source = "../ec2-role"

  name        = local.consumer_address.name
  policy_json = data.aws_iam_policy_document.consumer_address.json
  tags        = local.tags
}

module "consumer_address_asg" {
  source = "../asg"

  name                           = local.consumer_address.name
  image_id                       = data.aws_ssm_parameter.etl_al2023.value
  instance_type                  = local.consumer_address.instance_type
  subnet_ids                     = module.vpc.node_subnet_ids
  security_group_ids             = [aws_security_group.etl_clients.id]
  instance_profile_name          = module.consumer_address_role.instance_profile_name
  min_size                       = local.consumer_address.min_size
  max_size                       = local.consumer_address.max_size
  desired_size                   = local.consumer_address.desired_size
  refresh_min_healthy_percentage = local.consumer_address.refresh_min_healthy_percentage
  instance_tags                  = { EtlGroup = "consumer-address" }
  tags                           = local.tags

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", merge(local.etl_user_data_common, {
    group_key         = "consumer-address"
    kafka_user        = local.consumer_address.kafka_user
    script            = local.consumer_address.script
    run_lag_publisher = false
    log_group         = aws_cloudwatch_log_group.consumer_address.name
  }))

  # Outbound access (NAT route, VPC endpoints) must exist before the first instance boots.
  depends_on = [module.vpc, module.vpc_endpoints]
}

# Scale out and in on this consumer group's lag, and warn when the lag number stops arriving.
module "consumer_address_lag" {
  source = "../lag-scaling"

  name             = local.consumer_address.name
  asg_name         = module.consumer_address_asg.asg_name
  lag_group_id     = local.consumer_address.lag_group_id
  scaling_enabled  = local.consumer_address.max_size > local.consumer_address.min_size
  max_size         = local.consumer_address.max_size
  partition_count  = local.etl_partition_count
  metric_namespace = local.etl_metric_namespace
  alarm_actions    = local.etl_alarm_actions
  tags             = local.tags
}

resource "aws_cloudwatch_metric_alarm" "consumer_address_instances_down" {
  alarm_name          = "${local.consumer_address.name}-instances-down"
  alarm_description   = "Fewer than ${local.consumer_address.min_size} instance(s) of consumer-address are in service."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = module.consumer_address_asg.asg_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  threshold           = local.consumer_address.min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.etl_alarm_actions
  ok_actions    = local.etl_alarm_actions

  tags = local.tags
}