variable "name" {
  description = "Name of the role and of its instance profile."
  type        = string
}

variable "policy_json" {
  description = "What the instances may do: an IAM policy document (data.aws_iam_policy_document ... .json), attached to the role as an inline policy."
  type        = string
}

variable "policy_name" {
  type    = string
  default = "runtime"
}

variable "managed_policies" {
  description = "AWS-managed policies (by name) attached to the role. The defaults give Session Manager / Run Command and the CloudWatch agent."
  type        = list(string)
  default     = ["AmazonSSMManagedInstanceCore", "CloudWatchAgentServerPolicy"]
}

variable "tags" {
  type    = map(string)
  default = {}
}