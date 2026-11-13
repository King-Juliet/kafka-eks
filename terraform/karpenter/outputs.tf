output "queue_name" {
  description = "SQS interruption queue used by the controller."
  value       = aws_sqs_queue.this.name
}

output "node_iam_role_name" {
  description = "IAM role of every node Karpenter launches."
  value       = aws_iam_role.node.name
}