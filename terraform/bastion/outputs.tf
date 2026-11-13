output "instance_id" {
  description = "Target for aws ssm start-session."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "The bastion's Elastic IP. The region folder allows exactly this address (as a /32) on the Kubernetes API."
  value       = aws_eip.this.public_ip
}