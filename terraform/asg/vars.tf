variable "name" {
  description = "Name of the Auto Scaling Group. The launch template name starts with it and the instances get it as their Name tag."
  type        = string
}

variable "image_id" {
  description = "AMI the instances start from."
  type        = string
}

variable "instance_type" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets the instances are placed in. They never get a public IP, so use private subnets."
  type        = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_profile_name" {
  description = "IAM instance profile the instances run as (see the ec2-role module)."
  type        = string
}

variable "user_data" {
  description = "Boot script as plain text (this module base64-encodes it). null = no boot script."
  type        = string
  default     = null
}

variable "root_volume_gib" {
  description = "Size of the encrypted gp3 root volume."
  type        = number
  default     = 20
}

variable "min_size" {
  type = number
}

variable "max_size" {
  type = number
}

variable "desired_size" {
  description = "Starting size only. After the first apply scaling policies own the live value, so changing this later does nothing."
  type        = number

  validation {
    condition     = var.min_size <= var.desired_size && var.desired_size <= var.max_size
    error_message = "Need min_size <= desired_size <= max_size."
  }
}

variable "health_check_grace_period" {
  description = "Seconds a new instance is left alone before its health is judged."
  type        = number
  default     = 300
}

variable "refresh_min_healthy_percentage" {
  description = "Rolling replacement of instances (a new image or boot script): how much of the group must stay in service. 0 = stop the old instance BEFORE starting the new one, so a group of one never runs two at once."
  type        = number
  default     = 50
}

variable "refresh_instance_warmup" {
  description = "Seconds a replacement instance gets before the refresh moves on to the next one."
  type        = number
  default     = 120
}

variable "enabled_metrics" {
  description = "Group metrics sent to CloudWatch (namespace AWS/AutoScaling)."
  type        = list(string)
  default     = ["GroupInServiceInstances", "GroupDesiredCapacity"]
}

variable "instance_tags" {
  description = "Extra tags for the instances, on top of tags and Name."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}