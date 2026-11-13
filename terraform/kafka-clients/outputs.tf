output "asg_names" {
  value = { for k, v in aws_autoscaling_group.this : k => v.name }
}

output "security_group_id" {
  value = aws_security_group.this.id
}