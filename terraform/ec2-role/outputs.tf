# The profile name waits for the policies, so an instance that uses it never boots before its permissions exist.
output "instance_profile_name" {
  value      = aws_iam_instance_profile.this.name
  depends_on = [aws_iam_role_policy.this, aws_iam_role_policy_attachment.managed]
}

output "role_arn" {
  value = aws_iam_role.this.arn
}

output "role_name" {
  value = aws_iam_role.this.name
}