# ---------------------------------------------------------------- where layer 1's state lives
variable "region" {
  description = "AWS region. Must match the layer-1 folder and both backend.tf files (a check warns if the folder name differs)."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = "S3 bucket holding the Terraform state (same one backend.tf uses). This layer reads layer 1's outputs from it."
  type        = string
  default     = "juliet-terraform-state"
}

variable "layer1_state_key" {
  description = "State key of ../us-east-1."
  type        = string
  default     = "eks-kafka/us-east-1/terraform.tfstate"
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------- chart versions (verified as upstream tags on 2026-11-11, see CHANGELOG)
variable "karpenter_chart_version" {
  description = "Karpenter chart + CRD chart version. K8s 1.37 needs 1.15.x."
  type        = string
  default     = "1.15.1"
}

variable "lbc_chart_version" {
  description = "aws-load-balancer-controller chart version."
  type        = string
  default     = "3.6.2"
}

variable "eso_chart_version" {
  description = "external-secrets chart version."
  type        = string
  default     = "2.15.0"
}

# ---------------------------------------------------------------- Karpenter nodes
variable "ami_alias" {
  description = <<-EOT
    EC2NodeClass AMI alias. ASSUMPTION: starts at al2023@latest because a valid pinned release could not be looked up
    from here. PIN IT before production, e.g. al2023@v20260101 (see README "Pin the AMI").
    Kafka pools have a disruption budget of 0, so a new AMI never rolls Kafka nodes by surprise.
  EOT
  type        = string
  default     = "al2023@latest"
}

variable "node_root_volume_gib" {
  description = "ASSUMPTION: 30 GiB root volume (Kafka data is on separate PVCs)."
  type        = number
  default     = 30
}

variable "general_instance_types" {
  description = "ASSUMPTION: Argo CD + Entity Operator + Cruise Control + exporter need ~4-5 GiB, so t3.large."
  type        = list(string)
  default     = ["t3.large", "t3a.large"]
}

variable "general_cpu_limit" {
  description = "Max vCPU the general pool may ever provision (8 = four t3.large). Argo CD, the Kafka entity operator and Cruise Control need about two nodes; the ARC runner pods (up to 2 x 0.5 vCPU requested, more when a job is busy) and a node replacement need the rest."
  type        = string
  default     = "8"
}

variable "controller_instance_types" {
  description = "ASSUMPTION: t3.medium is the smallest sensible size for a KRaft controller."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "controller_cpu_limit" {
  description = "8 vCPU = 4 x t3.medium: the 3 controller nodes plus ONE spare so a node roll can start the replacement before stopping the old one. (Karpenter blocks only when usage is strictly above the limit.)"
  type        = string
  default     = "8"
}

variable "broker_instance_types" {
  description = "ASSUMPTION: t3.large (8 GiB) is the smallest sensible broker for a test."
  type        = list(string)
  default     = ["t3.large", "t3a.large"]
}

variable "broker_cpu_limit" {
  description = "10 vCPU = 5 x t3.large: 3 brokers + 1 for scaling out + 1 spare for a node roll."
  type        = string
  default     = "10"
}

# ---------------------------------------------------------------- External Secrets
variable "argocd_repo_secret_enabled" {
  description = "Create the ExternalSecret that feeds Argo CD its Git credentials. Safe to leave on: this layer also creates the argocd namespace, and the secret value is typed in once (/argocd/gitops-repo). ESO keeps retrying until the value exists."
  type        = bool
  default     = true
}