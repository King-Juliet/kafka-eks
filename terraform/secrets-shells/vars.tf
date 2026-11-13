variable "secret_names" {
  description = "Secrets Manager secret names to create as EMPTY shells, e.g. [\"/argocd/gitops-repo\"]."
  type        = set(string)
}

variable "recovery_window_in_days" {
  description = "Recovery window on delete. ASSUMPTION: 7 days for a test."
  type        = number
  default     = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}