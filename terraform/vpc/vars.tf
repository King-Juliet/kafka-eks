variable "name" {
  description = "Name prefix for the VPC and its resources (use the cluster name)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. ASSUMPTION: /16 is plenty; pods take VPC IPs (VPC CNI) so keep subnets large."
  type        = string
}

variable "azs" {
  description = "Availability zones to spread subnets across (3 recommended for Kafka)."
  type        = list(string)
}

variable "node_subnet_tier" {
  description = "Which subnet tier worker nodes live in: \"public\" (phase 1, no NAT cost) or \"private\" (phase 2)."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.node_subnet_tier)
    error_message = "node_subnet_tier must be \"public\" or \"private\"."
  }
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway (needed once nodes move to private subnets)."
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "One shared NAT (cheap, test) vs one per AZ (production)."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for the flow-log log group. ASSUMPTION: 14 days for a test."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}