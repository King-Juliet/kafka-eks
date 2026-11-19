variable "name" {
  description = "Prefix of the alarm names (use the ASG name)."
  type        = string
}

variable "asg_name" {
  description = "The Auto Scaling Group to scale."
  type        = string
}

variable "lag_group_id" {
  description = "Kafka consumer group whose lag (CloudWatch metric ConsumerLag, published by the lag publisher) drives the scaling."
  type        = string
}

variable "scaling_enabled" {
  description = "false = a group that never changes size: no scaling policies, only the \"lag metric missing\" alarm."
  type        = bool
  default     = true
}

variable "max_size" {
  description = "The ASG's max_size. Only used to refuse a maximum above the partition count."
  type        = number

  validation {
    condition     = var.max_size <= var.partition_count
    error_message = "A consumer group cannot use more instances than the topic has partitions (the extra consumers would sit idle)."
  }
}

variable "partition_count" {
  description = "Partitions of the topic the group reads."
  type        = number
}

variable "scale_out_lag_threshold" {
  description = "ASSUMPTION: 100 messages behind for 3 minutes in a row adds an instance. Not tuned against real traffic."
  type        = number
  default     = 100
}

variable "scale_in_lag_threshold" {
  description = "ASSUMPTION: 5 messages behind or less for 15 minutes in a row removes an instance."
  type        = number
  default     = 5
}

variable "metric_namespace" {
  description = "CloudWatch namespace the lag publisher writes to."
  type        = string
  default     = "KafkaEks"
}

variable "alarm_actions" {
  description = "What the \"lag metric missing\" alarm notifies (an SNS topic ARN). Empty = the alarm exists but notifies nobody."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}