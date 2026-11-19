# Scale an Auto Scaling Group on how far a Kafka consumer group is behind, and warn a human when the lag number
# stops arriving. The ASG itself is not created here (see the asg module).

# ------------------------------------------------------------------ scale on consumer-group lag

resource "aws_autoscaling_policy" "lag_out" {
  count = var.scaling_enabled ? 1 : 0

  name                      = "lag-scale-out"
  autoscaling_group_name    = var.asg_name
  policy_type               = "StepScaling"
  adjustment_type           = "ChangeInCapacity"
  metric_aggregation_type   = "Maximum"
  estimated_instance_warmup = 300

  # Step bounds are offsets from the alarm threshold: [threshold, threshold+400) adds 1, above that adds 2.
  step_adjustment {
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 400
    scaling_adjustment          = 1
  }

  step_adjustment {
    metric_interval_lower_bound = 400
    scaling_adjustment          = 2
  }
}

resource "aws_autoscaling_policy" "lag_in" {
  count = var.scaling_enabled ? 1 : 0

  name                    = "lag-scale-in"
  autoscaling_group_name  = var.asg_name
  policy_type             = "StepScaling"
  adjustment_type         = "ChangeInCapacity"
  metric_aggregation_type = "Maximum"

  step_adjustment {
    metric_interval_upper_bound = 0
    scaling_adjustment          = -1
  }
}

resource "aws_cloudwatch_metric_alarm" "lag_high" {
  count = var.scaling_enabled ? 1 : 0

  alarm_name          = "${var.name}-lag-high"
  alarm_description   = "Consumer group ${var.lag_group_id} is behind: add instances."
  namespace           = var.metric_namespace
  metric_name         = "ConsumerLag"
  dimensions          = { GroupId = var.lag_group_id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = var.scale_out_lag_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # no metric must never trigger a scale-out

  alarm_actions = [aws_autoscaling_policy.lag_out[0].arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lag_low" {
  count = var.scaling_enabled ? 1 : 0

  alarm_name          = "${var.name}-lag-low"
  alarm_description   = "Consumer group ${var.lag_group_id} has been caught up for a while: remove an instance."
  namespace           = var.metric_namespace
  metric_name         = "ConsumerLag"
  dimensions          = { GroupId = var.lag_group_id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 15
  datapoints_to_alarm = 15
  threshold           = var.scale_in_lag_threshold
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "missing" # no metric must never trigger a scale-in either

  alarm_actions = [aws_autoscaling_policy.lag_in[0].arn]

  tags = var.tags
}

# ------------------------------------------------------------------ tells a human

# The threshold is unreachable on purpose: this alarm fires only when the metric stops arriving
# (publisher down, Kafka unreachable, lag-monitor password wrong).
resource "aws_cloudwatch_metric_alarm" "lag_metric_missing" {
  alarm_name          = "${var.name}-lag-metric-missing"
  alarm_description   = "No ConsumerLag datapoints for ${var.lag_group_id}: autoscaling is blind. Check the lag publisher on the producer instance."
  namespace           = var.metric_namespace
  metric_name         = "ConsumerLag"
  dimensions          = { GroupId = var.lag_group_id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 1000000000000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions

  tags = var.tags
}