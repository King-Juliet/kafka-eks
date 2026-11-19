output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA certificate of the API server (used by the Kubernetes and Helm providers)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "node_security_group_id" {
  value = aws_security_group.node.id
}

output "cluster_security_group_id" {
  value = aws_security_group.cluster.id
}

output "node_role_name" {
  description = "IAM role of the system node group (layer 1 attaches the ECR pull-through-cache policy to it)."
  value       = aws_iam_role.node.name
}