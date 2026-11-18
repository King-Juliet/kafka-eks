output "asg_names" {
  value = { for k, v in aws_autoscaling_group.this : k => v.name }
}

output "security_group_id" {
  value = aws_security_group.this.id
}

output "role_arns" {
  value = { for k, v in aws_iam_role.this : k => v.arn }
}

output "log_groups" {
  value = { for k, v in aws_cloudwatch_log_group.this : k => v.name }
}

output "min_healthy_percentages" {
  description = "Per group: how much of the group must stay in service during a code roll (0 for the single-instance groups)."
  value       = { for k, g in var.groups : k => g.refresh_min_healthy_percentage }
}