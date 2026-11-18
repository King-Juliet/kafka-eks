variable "name" {
  description = "Name prefix and DB instance identifier (use the cluster name)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets (at least two AZs) for the DB subnet group."
  type        = list(string)
}

variable "client_security_group_ids" {
  description = "Security groups (name => id) allowed to reach PostgreSQL on 5432, e.g. { etl_clients = \"sg-...\", runner = \"sg-...\" }. Keys must be static strings."
  type        = map(string)
}

variable "kms_key_arn" {
  description = "CMK that encrypts storage, Performance Insights and the managed master-password secret."
  type        = string
}

variable "db_name" {
  description = "Initial database. The ETL scripts read it from DB_NAME."
  type        = string
  default     = "bitcoin_db"
}

variable "master_username" {
  description = "Master user. Its password is generated and kept by RDS in Secrets Manager (and rotated by RDS). Only the migration job uses it; the ETL uses its own user."
  type        = string
  default     = "etl_admin"
}

variable "engine_version" {
  description = "ASSUMPTION: PostgreSQL 16 (major only: RDS picks the current default minor and auto minor upgrades stay on). Not looked up; check it is offered in your region/account before the first apply."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "ASSUMPTION: db.t4g.large. Not sized from real load; the raw tables grow with every block, so watch CPU, memory and IOPS and resize."
  type        = string
  default     = "db.t4g.large"
}

variable "allocated_storage_gib" {
  description = "ASSUMPTION: 100 GiB to start (gp3)."
  type        = number
  default     = 100
}

variable "max_allocated_storage_gib" {
  description = "ASSUMPTION: storage autoscaling up to 500 GiB. Set 0 to turn autoscaling off."
  type        = number
  default     = 500
}

variable "multi_az" {
  description = "Standby in a second AZ (automatic failover). On for production."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "ASSUMPTION: 7 days of automated backups (point-in-time recovery)."
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "Refuse to delete the instance. Turn off deliberately before a destroy."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "monitoring_interval" {
  description = "Enhanced monitoring interval in seconds (0 turns it off; otherwise 1, 5, 10, 15, 30 or 60)."
  type        = number
  default     = 60

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be 0, 1, 5, 10, 15, 30 or 60."
  }
}