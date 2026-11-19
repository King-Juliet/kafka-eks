# External Secrets Operator (ESO) + its config (a ClusterSecretStore pointing at AWS Secrets Manager).
# Credentials come from EKS Pod Identity. The role may read /argocd/* and /kafka/* and WRITE /kafka/*
# (PushSecret copies the Kafka passwords and cluster CA out to Secrets Manager for clients outside the cluster).

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  secret_arns = [
    for prefix in var.secret_name_prefixes :
    "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${prefix}*"
  ]

  # Narrower list: only these prefixes are writable (PushSecret).
  push_secret_arns = [
    for prefix in var.push_secret_name_prefixes :
    "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${prefix}*"
  ]
}

# ------------------------------------------------------------------ AWS side: role, policy, Pod Identity association

data "aws_iam_policy_document" "pods_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                  = "${var.cluster_name}-external-secrets"
  assume_role_policy    = data.aws_iam_policy_document.pods_assume.json
  force_detach_policies = true

  tags = var.tags
}

data "aws_iam_policy_document" "this" {
  # Listing / batch reads cannot be limited to a prefix, so these two are on "*".
  statement {
    sid       = "ListAndBatchRead"
    actions   = ["secretsmanager:ListSecrets", "secretsmanager:BatchGetSecretValue"]
    resources = ["*"]
  }

  statement {
    sid = "ReadOurPrefixes"
    actions = [
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = local.secret_arns
  }

  # Needed so PushSecret can write new versions of the /kafka/* secrets (and nothing else).
  statement {
    sid       = "PushToOurPrefixes"
    actions   = ["secretsmanager:CreateSecret", "secretsmanager:PutSecretValue", "secretsmanager:TagResource", "secretsmanager:DeleteResourcePolicy"]
    resources = local.push_secret_arns
  }

  # Delete only what ESO itself tagged.
  statement {
    sid       = "DeleteOnlyWhatESOManages"
    actions   = ["secretsmanager:DeleteSecret"]
    resources = local.push_secret_arns

    condition {
      test     = "StringEquals"
      variable = "secretsmanager:ResourceTag/managed-by"
      values   = ["external-secrets"]
    }
  }

  # Secrets Manager decrypts with the key that encrypted each secret; keep that to this account + region.
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${local.partition}:kms:${var.region}:${local.account_id}:key/*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "external-secrets"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}

# Only when Argo CD pulls charts from the ECR cache: the same role makes the ECR login that Argo CD uses.
resource "aws_iam_role_policy_attachment" "ecr_pull" {
  count = length(var.argocd_oci_repos) > 0 ? 1 : 0

  role       = aws_iam_role.this.name
  policy_arn = var.ecr_pull_policy_arn
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn

  tags = var.tags
}

# ------------------------------------------------------------------ In-cluster: operator, then its config

resource "helm_release" "operator" {
  name             = "external-secrets"
  namespace        = var.namespace
  create_namespace = true
  chart            = "${path.module}/external-secrets-${var.chart_version}.tgz"

  values = [yamlencode({
    installCRDs  = true
    replicaCount = 1 # ASSUMPTION: 1 for a test. Use 2 + leaderElect=true in production.

    serviceAccount = { name = var.service_account }

    # ghcr.io/external-secrets/external-secrets, through your ECR. "global.repository" is used by the operator, the
    # webhook and the cert controller alike (they are all the same image).
    global = { repository = "${var.ghcr_mirror}/external-secrets/external-secrets" }

    nodeSelector = var.node_selector
    tolerations  = var.tolerations

    webhook = {
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
    }

    certController = {
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
    }
  })]

  depends_on = [aws_eks_pod_identity_association.this, aws_iam_role_policy.this]
}

# The cert-controller needs a moment to inject the CA into ESO's validating webhooks.
resource "time_sleep" "webhooks_ready" {
  create_duration = "30s"
  depends_on      = [helm_release.operator]
}

# Local chart in ./chart: the ClusterSecretStore (+ optional Argo CD repo credential ExternalSecret).
resource "helm_release" "config" {
  name      = "eso-config"
  namespace = var.namespace
  chart     = "${path.module}/chart"

  values = [yamlencode({
    region = var.region
    argocdRepoSecret = {
      enabled = var.argocd_repo_secret_enabled
    }
    argocdOciRepos = var.argocd_oci_repos
  })]

  depends_on = [time_sleep.webhooks_ready, aws_iam_role_policy_attachment.ecr_pull]
}