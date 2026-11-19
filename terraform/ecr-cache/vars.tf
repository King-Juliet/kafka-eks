variable "region" {
  description = "AWS region of the registry. The cache lives in one region; pulls from another region do not see it."
  type        = string
}

variable "upstreams" {
  description = <<-EOT
    Public registries to keep a copy of, keyed by the ECR repository prefix.
    Example: { quay = { registry_url = "quay.io" } } makes quay.io/prometheus/node-exporter available as
    <account>.dkr.ecr.<region>.amazonaws.com/quay/prometheus/node-exporter.
    registry_url             The upstream registry host.
    credential_secret_arn    Only for upstreams that need a login (ghcr.io, Docker Hub...). The secret must be named
                             ecr-pullthroughcache/<something> and hold {"username": "...", "accessToken": "..."}.
                             public.ecr.aws, quay.io and registry.k8s.io need none.
  EOT
  type = map(object({
    registry_url          = string
    credential_secret_arn = optional(string)
  }))

  validation {
    condition     = alltrue([for prefix in keys(var.upstreams) : can(regex("^[a-z0-9]+([._-][a-z0-9]+)*$", prefix))])
    error_message = "Each key (the ECR repository prefix) must be lower case letters, digits and . _ - only, for example \"quay\"."
  }

  validation {
    condition     = alltrue([for u in values(var.upstreams) : u.credential_secret_arn == null || can(regex(":secret:ecr-pullthroughcache/", u.credential_secret_arn))])
    error_message = "ECR only accepts a credential secret whose name starts with ecr-pullthroughcache/ (and is in this account and region)."
  }
}

variable "policy_name" {
  description = "Name of the IAM policy that lets a role pull through (and fill) the cache. Attach it to every role that pulls: nodes, and whatever fetches charts."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}