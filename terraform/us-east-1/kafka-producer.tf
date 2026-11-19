# The producer: exactly ONE instance (min = max = 1). It also runs the lag publisher, which writes the ConsumerLag
# metric the consumers scale on. Change the numbers in the locals below; the rest follows from them.
locals {
  producer = {
    name          = "${var.cluster_name}-etl-producer"
    kafka_user    = "producer-app"
    script        = "producer/block_data_producer.py"
    instance_type = "t3.small" # ASSUMPTION: not load-tested
    min_size      = 1
    max_size      = 1
    desired_size  = 1
    # Replace it by stopping the old instance BEFORE starting the new one: two producers must never run side by side.
    refresh_min_healthy_percentage = 0
  }
}

resource "aws_cloudwatch_log_group" "producer" {
  name              = "/${var.cluster_name}/etl/producer"
  retention_in_days = local.etl_log_retention_days
  tags              = local.tags
}

# The common permissions plus: its own Kafka password, the lag-monitor password, and writing the lag metric.
data "aws_iam_policy_document" "producer" {
  source_policy_documents = [data.aws_iam_policy_document.etl_common.json]

  statement {
    sid       = "ReadOwnKafkaPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local.etl_secret_arn_prefix}/kafka/clients/${local.producer.kafka_user}-*"]
  }

  statement {
    sid       = "ReadLagMonitorPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local.etl_secret_arn_prefix}/kafka/clients/${local.etl_lag_user}-*"]
  }

  statement {
    sid       = "PublishLagMetric"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource-level permissions; the condition below scopes it.

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.etl_metric_namespace]
    }
  }
}

module "producer_role" {
  source = "../ec2-role"

  name        = local.producer.name
  policy_json = data.aws_iam_policy_document.producer.json
  tags        = local.tags
}

module "producer_asg" {
  source = "../asg"

  name                           = local.producer.name
  image_id                       = data.aws_ssm_parameter.etl_al2023.value
  instance_type                  = local.producer.instance_type
  subnet_ids                     = module.vpc.node_subnet_ids
  security_group_ids             = [aws_security_group.etl_clients.id]
  instance_profile_name          = module.producer_role.instance_profile_name
  min_size                       = local.producer.min_size
  max_size                       = local.producer.max_size
  desired_size                   = local.producer.desired_size
  refresh_min_healthy_percentage = local.producer.refresh_min_healthy_percentage
  instance_tags                  = { EtlGroup = "producer" }
  tags                           = local.tags

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", merge(local.etl_user_data_common, {
    group_key         = "producer"
    kafka_user        = local.producer.kafka_user
    script            = local.producer.script
    run_lag_publisher = true
    log_group         = aws_cloudwatch_log_group.producer.name
  }))

  # Outbound access (NAT route, VPC endpoints) must exist before the first instance boots.
  depends_on = [module.vpc, module.vpc_endpoints]
}

resource "aws_cloudwatch_metric_alarm" "producer_instances_down" {
  alarm_name          = "${local.producer.name}-instances-down"
  alarm_description   = "Fewer than ${local.producer.min_size} instance(s) of the producer are in service."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = module.producer_asg.asg_name }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 10
  threshold           = local.producer.min_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = local.etl_alarm_actions
  ok_actions    = local.etl_alarm_actions

  tags = local.tags
}