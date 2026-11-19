output "endpoint_ids" {
  description = "Endpoint id per service name."
  value       = { for service, endpoint in aws_vpc_endpoint.this : service => endpoint.id }
}

output "security_group_id" {
  value = aws_security_group.this.id
}