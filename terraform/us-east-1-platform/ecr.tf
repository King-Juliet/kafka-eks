# Layer 1 builds the ECR pull-through cache (terraform/us-east-1/ecr.tf). This layer only has to let its own roles use it.
# Karpenter's nodes run Strimzi's Kafka pods, the Argo CD-managed ARC runners and everything else Karpenter places;
# they pull through the cache the first time an image is needed, so they need the cache policy on top of the
# AWS "PullOnly" one. (The system node group got it in layer 1; the External Secrets role gets it in its module.)
resource "aws_iam_role_policy_attachment" "karpenter_nodes_ecr_cache" {
  role       = module.karpenter.node_iam_role_name
  policy_arn = local.l1.ecr_cache_pull_policy_arn
}