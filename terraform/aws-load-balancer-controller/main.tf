# AWS Load Balancer Controller: turns Service type=LoadBalancer (class service.k8s.aws/nlb) into NLBs
# and Ingress / Gateway objects into ALBs.
# Pod Identity role + association first, then the Helm release (so the pods start with credentials).

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
  name                  = "${var.cluster_name}-aws-lbc"
  assume_role_policy    = data.aws_iam_policy_document.pods_assume.json
  force_detach_policies = true

  tags = var.tags
}

# The policy is the controller project's own file, copied unchanged (docs/install/iam_policy.json at tag v3.6.2).
# When you bump chart_version, replace iam_policy.json with the one from the new tag.
resource "aws_iam_role_policy" "this" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.this.id
  policy = file("${path.module}/iam_policy.json")
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn

  tags = var.tags
}

resource "helm_release" "this" {
  name       = "aws-load-balancer-controller"
  namespace  = var.namespace
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version

  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = var.region # IMDS is not reachable from pods (hop limit 1), so these are explicit
    vpcId        = var.vpc_id
    replicaCount = var.replicas

    serviceAccount = {
      create = true
      name   = var.service_account
    }

    nodeSelector = var.node_selector
    tolerations  = var.tolerations

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [aws_eks_pod_identity_association.this, aws_iam_role_policy.this]
}