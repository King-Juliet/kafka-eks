variable "name" {
  description = "Name prefix (use the cluster name)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets the runner lives in. It needs outbound internet (GitHub, AWS APIs) through NAT and a route to the private Kubernetes API."
  type        = list(string)
}

variable "github_repo" {
  description = "owner/repo the runner registers to."
  type        = string
}

variable "auth_secret_arn" {
  description = "Secrets Manager secret (JSON with key github_token) the runner reads to register itself."
  type        = string
}

variable "labels" {
  description = "Extra runner labels (self-hosted is always added by GitHub)."
  type        = list(string)
  default     = ["vpc-bootstrap"]
}

variable "instance_type" {
  description = "ASSUMPTION: t3.small is enough for terraform + kubectl + a Python migration. Not load-tested."
  type        = string
  default     = "t3.small"
}

variable "initial_desired_capacity" {
  description = "Runner count when the group is first created: 1 so the very first pipeline run can use it. CD scales it to 0 once ARC is ready, and Terraform ignores the live value afterwards."
  type        = number
  default     = 1
}

variable "runner_version" {
  description = "actions/runner release. Checked on the GitHub release page on 2026-11-18: this was the latest release. The runner updates itself after registering, so an older pin still works."
  type        = string
  default     = "2.338.0"
}

variable "runner_sha256" {
  description = "SHA-256 of actions-runner-linux-x64-<runner_version>.tar.gz (from the release page). Must be changed together with runner_version."
  type        = string
  default     = "af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32"
}

variable "root_volume_gib" {
  description = "ASSUMPTION: 30 GiB (Terraform providers, plugin cache, job workspaces)."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}