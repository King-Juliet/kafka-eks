variable "name" {
  description = "EKS cluster name."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Used for the node security-group rule that lets the internal Kafka NLBs reach the brokers."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for worker nodes (the node tier: public in phase 1, private in phase 2)."
  type        = list(string)
}

variable "control_plane_subnet_ids" {
  description = "Subnets for the control-plane ENIs. Kept on the PRIVATE tier in both phases so moving nodes later never touches the control plane."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly (only to api_allowed_cidrs). false = private endpoint only."
  type        = bool
  default     = true # keeps the old behaviour for anyone still calling this module the old way
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the PUBLIC Kubernetes API endpoint. Ignored when endpoint_public_access is false. Use your own /32, not 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "bootstrap_creator_admin" {
  description = "Give the identity that creates the cluster implicit cluster-admin. false = explicit access entries only (admin_principal_arns). Only read when the cluster is first created."
  type        = bool
  default     = true
}

variable "api_client_security_group_ids" {
  description = "Security groups (name => id) allowed to reach the Kubernetes API on 443, e.g. { runner = \"sg-...\" }. Needed when the endpoint is private. Keys must be static strings."
  type        = map(string)
  default     = {}
}

variable "secrets_kms_key_arn" {
  description = "CMK used for Kubernetes Secrets envelope encryption."
  type        = string
}

variable "ebs_kms_key_arn" {
  description = "CMK that encrypts the Kafka EBS volumes. The EBS CSI driver's role is granted use of it."
  type        = string
}

variable "admin_principal_arns" {
  description = "Extra IAM principals (roles/users) to give cluster-admin through EKS access entries. The identity running Terraform is added automatically."
  type        = list(string)
  default     = []
}

variable "system_instance_types" {
  description = "ASSUMPTION: t3.medium is the smallest size that fits Karpenter + CoreDNS + LBC + ESO + Strimzi operator."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "system_min_size" {
  type    = number
  default = 2
}

variable "system_max_size" {
  type    = number
  default = 3
}

variable "system_desired_size" {
  type    = number
  default = 2
}

variable "log_retention_days" {
  description = "Control-plane log retention. ASSUMPTION: 30 days for a test."
  type        = number
  default     = 30
}

variable "enable_network_policy" {
  description = "Turn on Kubernetes NetworkPolicy enforcement in the VPC CNI (Strimzi generates policies for Kafka pods)."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Protect the cluster from accidental deletion. ASSUMPTION: off for a test so destroy works."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}