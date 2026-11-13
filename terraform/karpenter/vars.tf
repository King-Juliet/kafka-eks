variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "region" {
  description = "AWS region. Passed to the controller explicitly because pods cannot read it from IMDS (hop limit 1)."
  type        = string
}

variable "chart_version" {
  description = "Karpenter chart + CRD chart version. K8s 1.37 needs 1.15.x."
  type        = string
}

variable "namespace" {
  type    = string
  default = "kube-system"
}

variable "service_account" {
  type    = string
  default = "karpenter"
}

variable "node_selector" {
  description = "Where the controller runs. Must be the always-on system node group (Karpenter cannot start on nodes it has to create)."
  type        = map(string)
}

variable "tolerations" {
  description = "Tolerations for the controller (the system node group is tainted)."
  type        = list(map(string))
}

variable "ami_alias" {
  description = "EC2NodeClass AMI alias, e.g. al2023@latest. Pin it before production (README \"Pin the AMI\")."
  type        = string
  default     = "al2023@latest"
}

variable "associate_public_ip" {
  description = "Phase 1 (public subnets): true. Phase 2 (private subnets + NAT): false."
  type        = bool
  default     = true
}

variable "node_root_volume_gib" {
  description = "Root volume size of Karpenter nodes. ASSUMPTION: 30 GiB (Kafka data is on separate PVCs)."
  type        = number
  default     = 30
}

variable "node_pools" {
  description = "Instance types and the max vCPU for each Karpenter NodePool: general, kafka-controllers, kafka-brokers. Taints, labels and disruption rules live in ./chart/values.yaml."
  type = map(object({
    instance_types = list(string)
    cpu_limit      = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}