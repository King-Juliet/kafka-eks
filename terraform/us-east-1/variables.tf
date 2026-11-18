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

variable "ci_name_prefix" {
  description = "Prefix of the GitHub OIDC roles created by ../bootstrap (<prefix>-gh-ci, <prefix>-gh-cd). The deploy role becomes cluster-admin, so this must match what bootstrap created."
  type        = string
  default     = "kafka-eks"
}

variable "runner_auth_secret_name" {
  description = "Secrets Manager secret (created by ../bootstrap) holding the GitHub token the runners register with."
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
variable "alarm_topic_arn" {
  description = "Optional SNS topic that receives the ETL alarms (lag metric missing, producer down). null = alarms exist but notify nobody."
  type        = string
  default     = null
}

variable "etl_groups" {
  description = <<-EOT
    The Auto Scaling Groups. The producer is exactly one instance. The block and address consumers scale on their
    consumer group's lag. The transaction consumer is pinned to one instance: it pairs block and transaction messages
    in memory, so splitting its partitions across instances would break the pairing.
    ASSUMPTION: instance types are guesses (not load-tested); lag thresholds live in the kafka-clients module.
  EOT
  type = map(object({
    kafka_user                     = string
    script                         = string
    instance_type                  = string
    min_size                       = number
    max_size                       = number
    desired_size                   = number
    lag_group_id                   = optional(string)
    run_lag_publisher              = optional(bool, false)
    refresh_min_healthy_percentage = optional(number, 50)
  }))
  default = {
    producer = {
      kafka_user                     = "producer-app"
      script                         = "producer/block_data_producer.py"
      instance_type                  = "t3.small"
      min_size                       = 1
      max_size                       = 1
      desired_size                   = 1
      run_lag_publisher              = true
      refresh_min_healthy_percentage = 0
    }
    consumer-block = {
      kafka_user    = "consumer-app"
      script        = "consumers/block_data_consumer.py"
      instance_type = "t3.medium"
      min_size      = 1
      max_size      = 5
      desired_size  = 1
      lag_group_id  = "bitcoin_block_consumer_group"
    }
    consumer-address = {
      kafka_user    = "consumer-app"
      script        = "consumers/address_data_consumer.py"
      instance_type = "t3.medium"
      min_size      = 1
      max_size      = 5
      desired_size  = 1
      lag_group_id  = "bitcoin_address_consumer_group"
    }
    consumer-transaction = {
      kafka_user    = "consumer-app"
      script        = "consumers/transaction_data_consumer.py"
      instance_type = "t3.medium"
      min_size      = 1
      max_size      = 1
      desired_size  = 1
      lag_group_id  = "bitcoin_consumer_group"
      # One instance and it must not run twice at once (in-memory pairing): replace it by stopping, then starting.
      refresh_min_healthy_percentage = 0
    }
  }
}