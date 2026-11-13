output "key_arns" {
  description = "Map of short-name => key ARN."
  value       = { for k, v in aws_kms_key.this : k => v.arn }
}

output "alias_names" {
  description = "Map of short-name => alias name."
  value       = { for k, v in aws_kms_alias.this : k => v.name }
}