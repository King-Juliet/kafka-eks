variable "name" {
  description = "StorageClass name. The Kafka node pools in gitops/ refer to this exact name."
  type        = string
  default     = "kafka-gp3"
}

variable "kms_key_arn" {
  description = "CMK that encrypts the EBS volumes (the 'ebs-kafka' key from the kms module)."
  type        = string
}

variable "iops" {
  description = "gp3 baseline IOPS."
  type        = number
  default     = 3000
}

variable "throughput" {
  description = "gp3 baseline throughput in MiB/s."
  type        = number
  default     = 125
}