output "registry_host" {
  description = "Your private registry host, <account>.dkr.ecr.<region>.amazonaws.com."
  value       = local.host
}

output "paths" {
  description = "Prefix -> where that upstream is served, e.g. quay = <host>/quay. Put the image or chart path after it: <host>/quay/prometheus/node-exporter."
  value       = { for prefix in keys(var.upstreams) : prefix => "${local.host}/${prefix}" }
}

output "puller_policy_arn" {
  description = "Attach this to every role that pulls through the cache."
  value       = aws_iam_policy.puller.arn
}