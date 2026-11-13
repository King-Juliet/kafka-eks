variable "name_prefix" {
  description = "Prefix for resource names (use the cluster name)."
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets for the ASGs (same tier as the EKS nodes)."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Phase 1 (public subnets): true so instances can download Kafka tools. Phase 2: false (NAT)."
  type        = bool
  default     = true
}

variable "bootstrap_servers" {
  description = "host:port of the external listener bootstrap NLB, e.g. xxxx.elb.eu-west-1.amazonaws.com:9094"
  type        = string
}

variable "kafka_download_url" {
  description = "ASSUMPTION: Kafka CLI tarball for the client tools. Must match your broker version family."
  type        = string
  default     = "https://archive.apache.org/dist/kafka/4.3.2/kafka_2.13-4.3.2.tgz"
}

variable "ca_secret_id" {
  description = "Secrets Manager secret holding the cluster CA certificate (pushed by ESO PushSecret)."
  type        = string
  default     = "/kafka/cluster/ca-crt"
}

variable "groups" {
  description = "ASGs to create. kafka_user must exist as a KafkaUser; its password is pushed to /kafka/clients/<kafka_user>."
  type = map(object({
    instance_type = string
    min_size      = number
    max_size      = number
    desired_size  = number
    kafka_user    = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}