variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "region" {
  type = string
}

variable "chart_version" {
  description = "external-secrets chart version. Selects the vendored file external-secrets-<version>.tgz in this folder, so a new version needs its .tgz added first."
  type        = string
}

variable "namespace" {
  type    = string
  default = "external-secrets"
}

variable "service_account" {
  type    = string
  default = "external-secrets"
}

variable "secret_name_prefixes" {
  description = "Secrets Manager name prefixes ESO may READ. /argocd/ = Argo CD Git credential; /kafka/ = Kafka client credentials."
  type        = list(string)
  default     = ["/argocd/", "/kafka/"]
}

variable "push_secret_name_prefixes" {
  description = "The subset of secret_name_prefixes that ESO may also WRITE (PushSecret copies the Kafka passwords + cluster CA here). Keep /argocd/ out: Argo CD's Git credential is read-only for the cluster."
  type        = list(string)
  default     = ["/kafka/"]
}

variable "argocd_repo_secret_enabled" {
  description = "Create the ExternalSecret that feeds Argo CD its Git credentials. Turn on AFTER Argo CD is installed (namespace argocd must exist) and /argocd/gitops-repo has a value."
  type        = bool
  default     = false
}

variable "node_selector" {
  description = "Where ESO runs (the system node group)."
  type        = map(string)
}

variable "tolerations" {
  description = "Tolerations for ESO (the system node group is tainted)."
  type        = list(map(string))
}

variable "tags" {
  type    = map(string)
  default = {}
}