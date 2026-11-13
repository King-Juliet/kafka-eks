# ---------------------------------------------------------------- general
variable "region" {
  description = "AWS region. ASSUMPTION: eu-west-1 (not given). The folder name, the region in backend.tf and this value must all match; a check warns if they do not."
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the prefix for most resource names."
  type        = string
  default     = "kafka-test"
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------- network
variable "vpc_cidr" {
  description = "ASSUMPTION: 10.20.0.0/16. If you change it, also update the CIDR in gitops/kafka/base/kafka.yaml (networkPolicyPeers)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of AZs. Kafka with RF=3 wants 3."
  type        = number
  default     = 3
}

variable "node_subnet_tier" {
  description = "\"public\" for phase 1 (testing), flip to \"private\" for phase 2 (also set enable_nat_gateway = true). Karpenter nodes and the client ASGs follow this setting."
  type        = string
  default     = "public"
}

variable "enable_nat_gateway" {
  description = "Turn on when moving nodes to private subnets."
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (cheap). false = one per AZ (production)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- EKS
variable "kubernetes_version" {
  description = "EKS version. 1.37 is the default here; 1.36 is the fallback if 1.37 add-ons misbehave."
  type        = string
  default     = "1.37"
}

variable "bastion_instance_type" {
  description = "ASSUMPTION: t3.micro. The bastion only forwards traffic; its Elastic IP is the one address allowed on the public Kubernetes API."
  type        = string
  default     = "t3.micro"
}

variable "api_tunnel_port" {
  description = "ASSUMPTION: 8443. Local port on your Mac where the Session Manager tunnel to the Kubernetes API listens. Terraform and kubectl both connect to https://localhost:<this port>. Any free port works."
  type        = number
  default     = 8443
}


variable "admin_principal_arns" {
  description = "Extra IAM role/user ARNs that should be cluster-admin (you, as creator, already are)."
  type        = list(string)
  default     = []
}

variable "system_instance_types" {
  description = "ASSUMPTION: t3.medium x2 for the system node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "log_retention_days" {
  description = "ASSUMPTION: 30 days for control-plane logs."
  type        = number
  default     = 30
}

variable "enable_network_policy" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  description = "Set true once this stops being a test cluster."
  type        = bool
  default     = false
}

variable "argocd_secret_names" {
  description = "Empty Secrets Manager shells to create for Argo CD (values filled in by hand)."
  type        = set(string)
  default     = ["/argocd/gitops-repo"]
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
  description = "Max vCPU the general pool may ever provision (4 = two t3.large)."
  type        = string
  default     = "4"
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
  description = "Create the ExternalSecret that feeds Argo CD its Git credentials. Turn on AFTER you installed Argo CD (namespace argocd must exist) and filled /argocd/gitops-repo."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------- producer / consumer ASGs
variable "kafka_bootstrap_servers" {
  description = <<-EOT
    Leave null until Kafka is running. Then set it to the external listener address, from:
    kubectl -n kafka get kafka kafka-test -o jsonpath='{.status.listeners[?(@.name=="external")].bootstrapServers}'
    While null, no client ASGs are created.
  EOT
  type        = string
  default     = null
}

variable "kafka_client_groups" {
  description = "ASSUMPTION: 1 small producer box and 1 small consumer box to start."
  type = map(object({
    instance_type = string
    min_size      = number
    max_size      = number
    desired_size  = number
    kafka_user    = string
  }))
  default = {
    producers = {
      instance_type = "t3.small"
      min_size      = 1
      max_size      = 3
      desired_size  = 1
      kafka_user    = "producer-app"
    }
    consumers = {
      instance_type = "t3.small"
      min_size      = 1
      max_size      = 3
      desired_size  = 1
      kafka_user    = "consumer-app"
    }
  }
}