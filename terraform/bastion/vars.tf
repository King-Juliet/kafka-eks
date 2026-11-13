variable "name" {
  description = "Name prefix for the bastion and its IAM role / security group (use the cluster name)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the bastion lives in."
  type        = string
}

variable "subnet_id" {
  description = "A PUBLIC subnet. The bastion needs a route to the internet gateway to reach Systems Manager and the EKS endpoint."
  type        = string
}

variable "instance_type" {
  description = "ASSUMPTION: t3.micro is enough for a jump host that only forwards traffic. Must be x86_64 unless you also change ami_ssm_parameter."
  type        = string
  default     = "t3.micro"
}

variable "ami_ssm_parameter" {
  description = "Public SSM parameter that holds the current Amazon Linux 2023 AMI id (x86_64). For Graviton instance types use ...al2023-ami-kernel-default-arm64."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "root_volume_gib" {
  description = "ASSUMPTION: 20 GiB is plenty; the AMI itself needs about 8."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}