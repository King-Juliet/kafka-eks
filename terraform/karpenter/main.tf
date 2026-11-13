# Karpenter, in three parts:
#   1. AWS side   : controller IAM role (Pod Identity), SQS interruption queue + EventBridge rules, node IAM role + EKS access entry
#   2. In-cluster : CRD chart, then the controller chart
#   3. NodePools  : the local chart in ./chart (1 EC2NodeClass + 3 NodePools)
# Everything the controller needs (queue name, node role) comes from part 1, so nothing is matched "by name convention".

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # Handy ARN prefixes for the policy below.
  ec2_arn = "arn:${local.partition}:ec2:${var.region}"
  iam_arn = "arn:${local.partition}:iam::${local.account_id}"
  eks_arn = "arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name}"
}

# ================================================================== 1. AWS side
# 1a. Interruption queue: EventBridge drops spot / health / rebalance / state-change events here and
#     Karpenter drains the node before AWS takes it away.

resource "aws_sqs_queue" "this" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "SqsWrite"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenyHTTP"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.this.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "this" {
  queue_url = aws_sqs_queue.this.url
  policy    = data.aws_iam_policy_document.queue.json
}

locals {
  interruption_events = {
    health = {
      description = "Karpenter interrupt - AWS health event"
      pattern     = { source = ["aws.health"], "detail-type" = ["AWS Health Event"] }
    }
    spot-interrupt = {
      description = "Karpenter interrupt - EC2 spot instance interruption warning"
      pattern     = { source = ["aws.ec2"], "detail-type" = ["EC2 Spot Instance Interruption Warning"] }
    }
    rebalance = {
      description = "Karpenter interrupt - EC2 instance rebalance recommendation"
      pattern     = { source = ["aws.ec2"], "detail-type" = ["EC2 Instance Rebalance Recommendation"] }
    }
    state-change = {
      description = "Karpenter interrupt - EC2 instance state-change notification"
      pattern     = { source = ["aws.ec2"], "detail-type" = ["EC2 Instance State-change Notification"] }
    }
    capacity-reservation = {
      description = "Karpenter interrupt - EC2 capacity reservation instance interruption warning"
      pattern     = { source = ["aws.ec2"], "detail-type" = ["EC2 Capacity Reservation Instance Interruption Warning"] }
    }
  }
}

resource "aws_cloudwatch_event_rule" "interruption" {
  for_each = local.interruption_events

  name          = "${var.cluster_name}-karpenter-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "interruption" {
  for_each = local.interruption_events

  rule      = aws_cloudwatch_event_rule.interruption[each.key].name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.this.arn
}

# 1b. Node role: used by every node Karpenter launches. The access entry (type EC2_LINUX) lets those nodes join.

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name                  = "${var.cluster_name}-karpenter-node"
  assume_role_policy    = data.aws_iam_policy_document.node_assume.json
  force_detach_policies = true

  tags = var.tags
}

locals {
  node_policies = [
    "AmazonEKSWorkerNodePolicy",          # kubelet <-> EKS
    "AmazonEC2ContainerRegistryPullOnly", # pull images from ECR
    "AmazonEKS_CNI_Policy",               # aws-node (VPC CNI) manages ENIs/IPs with the node role
    "AmazonSSMManagedInstanceCore",       # Session Manager instead of SSH keys
  ]
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset(local.node_policies)

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.key}"
}

resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"

  tags = var.tags
}

# 1c. Controller role (Pod Identity). Everything that creates or deletes EC2 is limited by tags
#     (this cluster + a Karpenter NodePool). The statements are ported from modules/karpenter/policy.tf in
#     terraform-aws-modules/eks v21.29.0. When you bump the chart, diff them against the CloudFormation
#     template shipped with that Karpenter release.

data "aws_iam_policy_document" "pods_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name                  = "${var.cluster_name}-karpenter-controller"
  assume_role_policy    = data.aws_iam_policy_document.pods_assume.json
  force_detach_policies = true

  tags = var.tags
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid     = "AllowScopedEC2InstanceAccessActions"
    actions = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = [
      "arn:${local.partition}:ec2:${var.region}::image/*",
      "arn:${local.partition}:ec2:${var.region}::snapshot/*",
      "${local.ec2_arn}:*:security-group/*",
      "${local.ec2_arn}:*:subnet/*",
      "${local.ec2_arn}:*:capacity-reservation/*",
      "${local.ec2_arn}:*:placement-group/*",
    ]
  }

  statement {
    sid       = "AllowScopedEC2LaunchTemplateAccessActions"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = ["${local.ec2_arn}:*:launch-template/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedEC2InstanceActionsWithTags"
    actions = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
    resources = [
      "${local.ec2_arn}:*:fleet/*",
      "${local.ec2_arn}:*:instance/*",
      "${local.ec2_arn}:*:volume/*",
      "${local.ec2_arn}:*:network-interface/*",
      "${local.ec2_arn}:*:launch-template/*",
      "${local.ec2_arn}:*:spot-instances-request/*",
      "${local.ec2_arn}:*:capacity-reservation/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedResourceCreationTagging"
    actions = ["ec2:CreateTags"]
    resources = [
      "${local.ec2_arn}:*:fleet/*",
      "${local.ec2_arn}:*:instance/*",
      "${local.ec2_arn}:*:volume/*",
      "${local.ec2_arn}:*:network-interface/*",
      "${local.ec2_arn}:*:launch-template/*",
      "${local.ec2_arn}:*:spot-instances-request/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedResourceTagging"
    actions   = ["ec2:CreateTags"]
    resources = ["${local.ec2_arn}:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
    }
  }

  statement {
    sid     = "AllowScopedDeletion"
    actions = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
    resources = [
      "${local.ec2_arn}:*:instance/*",
      "${local.ec2_arn}:*:launch-template/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowRegionalReadActions"
    resources = ["*"]
    actions = [
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:DescribePlacementGroups",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${var.region}::parameter/aws/service/*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowZonalShiftReadActions"
    actions   = ["arc-zonal-shift:GetManagedResource"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "arc-zonal-shift:ResourceIdentifier"
      values   = [local.eks_arn]
    }
  }

  statement {
    sid       = "AllowInterruptionQueueActions"
    actions   = ["sqs:DeleteMessage", "sqs:GetQueueUrl", "sqs:ReceiveMessage"]
    resources = [aws_sqs_queue.this.arn]
  }

  statement {
    sid       = "AllowPassingInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.node.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Karpenter v1 creates and deletes its own instance profiles (one per EC2NodeClass).
  statement {
    sid       = "AllowScopedInstanceProfileCreationActions"
    actions   = ["iam:CreateInstanceProfile"]
    resources = ["${local.iam_arn}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileTagActions"
    actions   = ["iam:TagInstanceProfile"]
    resources = ["${local.iam_arn}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileActions"
    actions   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
    resources = ["${local.iam_arn}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [var.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowInstanceProfileReadActions"
    actions   = ["iam:GetInstanceProfile"]
    resources = ["${local.iam_arn}:instance-profile/*"]
  }

  statement {
    sid       = "AllowUnscopedInstanceProfileListAction"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    actions   = ["eks:DescribeCluster"]
    resources = [local.eks_arn]
  }
}

resource "aws_iam_role_policy" "controller" {
  name   = "karpenter-controller"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller.json
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.controller.arn

  tags = var.tags
}

# ================================================================== 2. In-cluster: CRDs, then the controller

# CRDs come from their own chart so Helm manages their upgrades.
resource "helm_release" "crd" {
  name       = "karpenter-crd"
  namespace  = var.namespace
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.chart_version
}

resource "helm_release" "controller" {
  name       = "karpenter"
  namespace  = var.namespace
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_version
  skip_crds  = true
  timeout    = 600

  values = [yamlencode({
    replicas       = 2
    nodeSelector   = var.node_selector
    tolerations    = var.tolerations
    serviceAccount = { name = var.service_account }

    settings = {
      clusterName       = var.cluster_name
      interruptionQueue = aws_sqs_queue.this.name
    }

    controller = {
      # IMDS hop limit is 1, so pods cannot ask the instance for the region - tell Karpenter directly.
      env = [{ name = "AWS_REGION", value = var.region }]
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]

  # The Pod Identity association must exist BEFORE the pods start, or they get no AWS credentials.
  depends_on = [
    helm_release.crd,
    aws_eks_pod_identity_association.karpenter,
    aws_iam_role_policy.controller,
    aws_eks_access_entry.node,
    aws_iam_role_policy_attachment.node,
    aws_sqs_queue_policy.this,
    aws_cloudwatch_event_target.interruption,
  ]
}

# NOTE: bump `version` in ./chart/Chart.yaml whenever you edit the chart templates,
# otherwise the Helm provider may not notice the change.
resource "helm_release" "nodepools" {
  name      = "karpenter-nodepools"
  namespace = var.namespace
  chart     = "${path.module}/chart"

  values = [yamlencode({
    clusterName              = var.cluster_name
    nodeRoleName             = aws_iam_role.node.name
    amiAlias                 = var.ami_alias
    associatePublicIPAddress = var.associate_public_ip
    rootVolumeGiB            = var.node_root_volume_gib

    pools = {
      for name, pool in var.node_pools : name => {
        instanceTypes = pool.instance_types
        cpuLimit      = pool.cpu_limit
      }
    }
  })]

  depends_on = [helm_release.controller]
}