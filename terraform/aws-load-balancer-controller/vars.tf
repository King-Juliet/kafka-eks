variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  description = "VPC the cluster lives in (the controller cannot discover it from IMDS)."
  type        = string
}

variable "chart_version" {
  description = "aws-load-balancer-controller chart version, fetched from https://aws.github.io/eks-charts. iam_policy.json in this folder must come from the same release tag."
  type        = string
}

variable "public_ecr_mirror" {
  description = "Your ECR copy of public.ecr.aws: <account>.dkr.ecr.<region>.amazonaws.com/ecr-public (no scheme, no trailing slash). The controller image is pulled from here."
  type        = string
}

variable "namespace" {
  type    = string
  default = "kube-system"
}

variable "service_account" {
  type    = string
  default = "aws-load-balancer-controller"
}

variable "replicas" {
  type    = number
  default = 2
}

variable "node_selector" {
  description = "Where the controller runs (the system node group)."
  type        = map(string)
}

variable "tolerations" {
  description = "Tolerations for the controller (the system node group is tainted)."
  type        = list(map(string))
}

variable "tags" {
  type    = map(string)
  default = {}
}