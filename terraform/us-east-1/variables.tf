# ---------------------------------------------------------------- general

variable "region" {
  description = "AWS region. ASSUMPTION: us-east-1 (not given). The folder name, the region in backend.tf and this value must all match; a check warns if they do not."
  type        = string
  default     = "us-east-1"
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
  description = "\"private\" for production: Kafka nodes, ETL instances and runners have no public IP and reach the internet through NAT. (\"public\" was the phase-1 test setting.) Karpenter nodes and the client ASGs follow this setting."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["public", "private"], var.node_subnet_tier)
    error_message = "node_subnet_tier must be \"public\" or \"private\"."
  }
}

variable "enable_nat_gateway" {
  description = "Needed while nodes are in private subnets (image pulls, GitHub, Blockstream API, package mirrors)."
  type        = bool
  default     = true
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

variable "admin_principal_arns" {
  description = "Extra IAM role/user ARNs that should be cluster-admin, e.g. your SSO admin role. The deploy role is added automatically (locals.tf). Do NOT list the identity that first created the cluster by hand if it already has implicit admin: EKS refuses a duplicate entry."
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
  description = "Protect the EKS cluster from accidental deletion. On for production; switch it off deliberately (and apply) before any terraform destroy."
  type        = bool
  default     = true
}

variable "argocd_secret_names" {
  description = "Empty Secrets Manager shells to create for Argo CD (values filled in by hand, once)."
  type        = set(string)
  default     = ["/argocd/gitops-repo"]
}


# ---------------------------------------------------------------- CI/CD and runners
variable "github_repo" {
  description = "owner/repo that the bootstrap runner registers to."
  type        = string
  default     = "King-Juliet/kafka-eks"
}

variable "deploy_role_arn" {
  description = "ARN of the GitHub OIDC role you created in the console. It becomes cluster-admin (it runs the platform layer). The workflows pass it in from the repository variable AWS_ROLE_ARN (TF_VAR_deploy_role_arn). Must be a plain role ARN with no path."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[^/]+$", var.deploy_role_arn))
    error_message = "deploy_role_arn must look like arn:aws:iam::123456789012:role/NAME (no path)."
  }
}

variable "runner_auth_secret_name" {
  description = "Secrets Manager secret holding the GitHub token the runners register with. You create it once by hand (README step 2)."
  type        = string
  default     = "/github/runner-auth"
}

variable "runner_instance_type" {
  description = "ASSUMPTION: t3.small for the bootstrap runner."
  type        = string
  default     = "t3.small"
}

# ---------------------------------------------------------------- database
variable "db_engine_version" {
  description = "ASSUMPTION: PostgreSQL 16 (major only). Not looked up; confirm it is offered in the region before the first apply."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "ASSUMPTION: db.t4g.large. Not sized from real load."
  type        = string
  default     = "db.t4g.large"
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_deletion_protection" {
  description = "Refuse to delete the database. Switch off deliberately (and apply) before a destroy."
  type        = bool
  default     = true
}

variable "db_app_secret_name" {
  description = "Secrets Manager secret holding the ETL's own DB user (written by scripts/db_migrate.py)."
  type        = string
  default     = "/kafka-eks/db/etl-app"
}

# ---------------------------------------------------------------- producer / consumer ASGs
# Their sizes and instance types are the locals at the top of kafka-producer.tf and kafka-consumer-*.tf.
variable "alarm_topic_arn" {
  description = "Optional SNS topic that receives the ETL alarms (lag metric missing, producer down). null = alarms exist but notify nobody."
  type        = string
  default     = null
}


variable "ghcr_pull_secret_name" {
  description = "Secrets Manager secret holding the GitHub login ECR uses to pull ghcr.io images and charts through the cache. You create it once by hand (README step 3). ECR only accepts a name that starts with ecr-pullthroughcache/."
  type        = string
  default     = "ecr-pullthroughcache/ghcr"

  validation {
    condition     = startswith(var.ghcr_pull_secret_name, "ecr-pullthroughcache/")
    error_message = "ECR only accepts a credential secret whose name starts with ecr-pullthroughcache/."
  }
}