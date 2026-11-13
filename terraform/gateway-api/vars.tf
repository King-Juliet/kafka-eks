variable "namespace" {
  description = "Namespace that holds the Helm release record. The CRDs themselves are cluster-wide."
  type        = string
  default     = "kube-system"
}