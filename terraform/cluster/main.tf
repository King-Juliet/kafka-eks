# EKS control plane + a small managed "system" node group + core add-ons, all as plain aws_* resources.
# NOT Auto Mode: compute_config is left unset. Karpenter (see ../karpenter) adds all other nodes.
#
# Read it top to bottom:
#   1. cluster IAM role + log group + security groups
#   2. the cluster itself + admin access entries
#   3. node IAM role + launch template + the "system" node group
#   4. add-ons (CNI / kube-proxy / pod-identity-agent first, then CoreDNS / metrics-server / EBS CSI)
#   5. IAM role for the EBS CSI driver (Pod Identity)

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition

  # Trust policy shared by both Pod Identity roles in this folder.
  pods_principal = "pods.eks.amazonaws.com"
}

# ------------------------------------------------------------------ 1a. cluster IAM role

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name                  = "${var.name}-cluster"
  assume_role_policy    = data.aws_iam_policy_document.cluster_assume.json
  force_detach_policies = true

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# The control plane encrypts Kubernetes Secrets with our CMK, so its role needs to use that key.
data "aws_iam_policy_document" "cluster_encryption" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ListGrants", "kms:DescribeKey"]
    resources = [var.secrets_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "cluster_encryption" {
  name   = "secrets-encryption"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_encryption.json
}

# ------------------------------------------------------------------ 1b. control-plane log group
# Created before the cluster so we own it (and its retention); EKS would otherwise create one that never expires.

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ------------------------------------------------------------------ 1c. security groups
# Two groups, one rule set each way:
#   cluster SG : attached to the control-plane ENIs. Only allows nodes to reach the API (443).
#   node SG    : attached to every node (system node group AND Karpenter nodes - Karpenter finds it by the
#                karpenter.sh/discovery tag). Allows the control plane in on the ports it needs.

resource "aws_security_group" "cluster" {
  name        = "${var.name}-cluster"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-cluster" })
}

resource "aws_security_group" "node" {
  name        = "${var.name}-node"
  description = "EKS node shared security group"
  vpc_id      = var.vpc_id

  tags = merge(
    var.tags,
    {
      Name                                = "${var.name}-node"
      "kubernetes.io/cluster/${var.name}" = "owned"
      "karpenter.sh/discovery"            = var.name # Karpenter's EC2NodeClass selects this SG by tag
    }
  )
}

locals {
  # Ports the control plane (cluster SG) may reach on nodes. 10250 = kubelet; the rest are admission-webhook ports.
  # The list is the same one the community EKS module opens by default.
  node_from_cluster = {
    "443"   = "Cluster API to node groups"
    "4443"  = "Cluster API to node 4443/tcp webhook"
    "6443"  = "Cluster API to node 6443/tcp webhook"
    "8443"  = "Cluster API to node 8443/tcp webhook"
    "9443"  = "Cluster API to node 9443/tcp webhook"
    "10250" = "Cluster API to node kubelets"
    "10251" = "Cluster API to node 10251/tcp webhook"
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Node groups to cluster API"
}

# Private API endpoint: callers inside the VPC (CI runners, an SSM port-forward host) reach the API through the
# control-plane ENIs, which carry this security group. Static map keys (e.g. "runner") keep for_each plannable
# even though the security group IDs are only known after they are created.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_api_clients" {
  for_each = var.api_client_security_group_ids

  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Kubernetes API from ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "node_from_cluster" {
  for_each = local.node_from_cluster

  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  description                  = each.value
}

resource "aws_vpc_security_group_ingress_rule" "node_self_dns_tcp" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 53
  to_port                      = 53
  description                  = "Node to node CoreDNS"
}

resource "aws_vpc_security_group_ingress_rule" "node_self_dns_udp" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "udp"
  from_port                    = 53
  to_port                      = 53
  description                  = "Node to node CoreDNS UDP"
}

resource "aws_vpc_security_group_ingress_rule" "node_self_ephemeral" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 1025
  to_port                      = 65535
  description                  = "Node to node ingress on ephemeral ports (pod to pod, Kafka replication)"
}

# Internal Kafka NLBs (IP targets) send client + health-check traffic straight to pod IPs.
resource "aws_vpc_security_group_ingress_rule" "node_kafka_external" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 9094
  to_port           = 9094
  description       = "Kafka external listener (9094) from inside the VPC (internal NLBs and clients in the VPC)"
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
}

# ------------------------------------------------------------------ 2a. the cluster

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  deletion_protection       = var.deletion_protection

  # The add-ons below install the CNI, kube-proxy and CoreDNS. Without this EKS would install its own
  # self-managed copies first and the add-ons would fight them.
  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API" # access entries only, no aws-auth ConfigMap

    # true  = whoever runs `terraform apply` becomes cluster-admin automatically. (Then do not list that same
    #         identity in admin_principal_arns - EKS refuses a duplicate entry.)
    # false = nobody is implicit; everyone who needs access is an explicit entry in admin_principal_arns.
    #         The production pipeline uses this so access never depends on WHO ran the first apply.
    # Create-time switch only (see ignore_changes below): an existing cluster keeps what it was built with.
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_creator_admin
  }

  vpc_config {
    subnet_ids         = var.control_plane_subnet_ids # control-plane ENIs (always the private tier)
    security_group_ids = [aws_security_group.cluster.id]

    # Private always on. Public only while var.endpoint_public_access is true (then only from api_allowed_cidrs).
    # Production sets it to false: the API is reachable from inside the VPC only (runners, SSM port-forward).
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = true
    public_access_cidrs     = var.endpoint_public_access ? var.api_allowed_cidrs : null
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = var.secrets_kms_key_arn
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_encryption,
    aws_cloudwatch_log_group.cluster,
    aws_vpc_security_group_ingress_rule.cluster_from_nodes,
  ]

  lifecycle {
    # Both are create-time switches; changing them later would force a new cluster.
    ignore_changes = [
      access_config[0].bootstrap_cluster_creator_admin_permissions,
      bootstrap_self_managed_addons,
    ]
  }
}

# ------------------------------------------------------------------ 2b. extra admins (access entries)

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = aws_eks_access_entry.admin

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ------------------------------------------------------------------ 3a. system node group: IAM role

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
  name                  = "${var.name}-system-node"
  assume_role_policy    = data.aws_iam_policy_document.node_assume.json
  force_detach_policies = true

  tags = var.tags
}

locals {
  node_policies = [
    "AmazonEKSWorkerNodePolicy",          # kubelet <-> EKS
    "AmazonEC2ContainerRegistryReadOnly", # pull images from ECR
    "AmazonEKS_CNI_Policy",               # aws-node (VPC CNI) manages ENIs/IPs with the node role
    "AmazonSSMManagedInstanceCore",       # Session Manager instead of SSH keys
  ]
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset(local.node_policies)

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.key}"
}

# ------------------------------------------------------------------ 3b. system node group: launch template

resource "aws_launch_template" "system" {
  name_prefix            = "${var.name}-system-"
  description            = "System managed node group for ${var.name}"
  update_default_version = true

  # Only our node SG. (The EKS-created "primary" cluster SG is deliberately NOT attached: the load balancer
  # controller needs exactly one cluster-tagged SG per node.)
  vpc_security_group_ids = [aws_security_group.node.id]

  # IMDSv2 only, hop limit 1: pods cannot reach the node role through IMDS.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])

    content {
      resource_type = tag_specifications.key
      tags          = merge(var.tags, { Name = "${var.name}-system" })
    }
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------ 3c. system node group

resource "aws_eks_node_group" "system" {
  cluster_name           = aws_eks_cluster.this.name
  node_group_name_prefix = "system-"
  node_role_arn          = aws_iam_role.node.arn
  subnet_ids             = var.subnet_ids
  version                = aws_eks_cluster.this.version

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = var.system_instance_types

  scaling_config {
    min_size     = var.system_min_size
    max_size     = var.system_max_size
    desired_size = var.system_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  labels = { workload = "system" }

  # Only critical add-ons (which tolerate this) run here; Argo CD, Entity Operator etc. go to Karpenter nodes.
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = merge(var.tags, { Name = "${var.name}-system" })

  # Nodes need the CNI before they can become Ready, so those add-ons go in first.
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.before_nodes,
  ]

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [scaling_config[0].desired_size] # leave scaling to whoever changes it later
  }
}

# ------------------------------------------------------------------ 4. add-ons
# Versions resolve to the latest one compatible with the cluster at plan time (most_recent = true).

locals {
  # Installed BEFORE any node exists (they are DaemonSets, so they are happy with zero nodes).
  addons_before_nodes = {
    "eks-pod-identity-agent" = null
    "vpc-cni"                = jsonencode({ enableNetworkPolicy = tostring(var.enable_network_policy) })
    "kube-proxy"             = null
  }

  # Installed AFTER the system nodes are up (they are Deployments and need somewhere to run).
  addons_after_nodes = {
    "coredns"        = null
    "metrics-server" = null
  }
}

data "aws_eks_addon_version" "this" {
  for_each = toset(concat(keys(local.addons_before_nodes), keys(local.addons_after_nodes), ["aws-ebs-csi-driver"]))

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "before_nodes" {
  for_each = local.addons_before_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "after_nodes" {
  for_each = local.addons_after_nodes

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  configuration_values        = each.value
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The node DaemonSet MUST run on the tainted Kafka nodes or volumes will not attach.
  configuration_values = jsonencode({
    node = { tolerateAllTaints = true }
  })

  # The add-on creates the Pod Identity association itself (no separate aws_eks_pod_identity_association needed).
  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  tags = var.tags

  depends_on = [
    aws_eks_node_group.system,
    aws_iam_role_policy_attachment.ebs_csi,
    aws_iam_role_policy.ebs_csi_kms,
  ]
}

# ------------------------------------------------------------------ 5. EBS CSI driver role (Pod Identity)

data "aws_iam_policy_document" "pods_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = [local.pods_principal]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name                  = "${var.name}-ebs-csi"
  assume_role_policy    = data.aws_iam_policy_document.pods_assume.json
  force_detach_policies = true

  tags = var.tags
}

# AWS-managed policy: create/attach/delete/snapshot EBS volumes for PersistentVolumeClaims.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# The Kafka volumes are encrypted with our CMK; the managed policy does not cover a customer key.
data "aws_iam_policy_document" "ebs_csi_kms" {
  statement {
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = [var.ebs_kms_key_arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = [var.ebs_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "ebs_csi_kms" {
  name   = "ebs-kms"
  role   = aws_iam_role.ebs_csi.id
  policy = data.aws_iam_policy_document.ebs_csi_kms.json
}