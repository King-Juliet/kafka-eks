# A private copy of the public images and Helm charts the cluster needs, kept in your own ECR (a "pull through cache").
#
# How it works: you ask your registry for <account>.dkr.ecr.<region>.amazonaws.com/quay/prometheus/node-exporter:v1.8.2.
# The first time, ECR fetches it from quay.io and keeps it. After that it is served from your registry, and ECR looks
# upstream for a newer copy of the same tag at most once every 24 hours (if upstream is down, the last copy is served).
# Helm charts are OCI artifacts, so the same works for charts. This module knows nothing about Kafka or Argo CD:
# give it a list of upstream registries and it builds the cache for them.
#
# Not covered: classic (HTTP) Helm repositories such as https://aws.github.io/eks-charts. ECR cannot cache those.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  host       = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

# One rule per upstream registry: "anything under <prefix>/ comes from <registry_url>".
resource "aws_ecr_pull_through_cache_rule" "this" {
  for_each = var.upstreams

  ecr_repository_prefix = each.key
  upstream_registry_url = each.value.registry_url
  credential_arn        = each.value.credential_secret_arn
}

# Settings for the repositories ECR creates by itself on the first pull. Tags stay mutable on purpose: ECR has to be
# able to replace a tag when upstream moves it (for example ":latest"); immutable tags would freeze the first copy.
# Kept simple: AWS-owned encryption (a KMS key or resource tags would also need a repository-creation role).
resource "aws_ecr_repository_creation_template" "this" {
  for_each = var.upstreams

  prefix               = each.key
  description          = "Created by the pull-through cache rule for ${each.value.registry_url}"
  applied_for          = ["PULL_THROUGH_CACHE"]
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# What a role needs to use the cache. The first pull of an image creates its repository and imports it, so pulling
# alone (the AWS "ReadOnly" / "PullOnly" policies) is not enough. Limited to the cache prefixes.
data "aws_iam_policy_document" "puller" {
  statement {
    sid       = "Login"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action cannot be limited to a repository
  }

  statement {
    sid = "PullAndFillTheCache"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchImportUpstreamImage", # first pull: ECR fetches the image from the upstream registry
      "ecr:CreateRepository",         # first pull: the repository that will hold the copy does not exist yet
    ]
    resources = [
      for prefix in sort(keys(var.upstreams)) :
      "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${prefix}/*"
    ]
  }
}

resource "aws_iam_policy" "puller" {
  name        = var.policy_name
  description = "Pull images and charts through the ECR pull-through cache (${join(", ", sort(keys(var.upstreams)))})"
  policy      = data.aws_iam_policy_document.puller.json

  tags = var.tags
}