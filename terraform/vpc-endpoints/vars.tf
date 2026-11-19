variable "name" {
  description = "Name prefix (use the cluster name)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "Who may call the endpoints: everything inside this CIDR."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets, one per AZ. Each gets a network interface for every endpoint."
  type        = list(string)
}

variable "services" {
  description = "AWS services to reach privately, by endpoint name, e.g. [\"secretsmanager\", \"logs\"]."
  type        = list(string)
  default     = ["secretsmanager"]
}

variable "tags" {
  type    = map(string)
  default = {}
}