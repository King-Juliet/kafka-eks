output "alarm_names" {
  value = concat(
    aws_cloudwatch_metric_alarm.lag_high[*].alarm_name,
    aws_cloudwatch_metric_alarm.lag_low[*].alarm_name,
    [aws_cloudwatch_metric_alarm.lag_metric_missing.alarm_name],
  )
}