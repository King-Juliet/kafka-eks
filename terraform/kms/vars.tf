variable "name_prefix" {
  description = "Prefix for key aliases (use the cluster name)."
  type        = string
}

variable "keys" {
  description = "Map of key short-name => description. One CMK is created per entry."
  type        = map(string)
}

variable "deletion_window_in_days" {
  description = "Waiting period before a deleted key is destroyed."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}