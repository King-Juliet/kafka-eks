output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private API endpoint (resolves only inside the VPC)."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA of the API server. A public certificate, not a secret. Layer 2 uses it to talk to the cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "node_subnet_ids" {
  value = module.vpc.node_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "node_subnet_tier" {
  description = "Layer 2 reads this to decide whether Karpenter nodes get public IPs."
  value       = var.node_subnet_tier
}

output "kafka_ebs_kms_key_arn" {
  value = module.kms.key_arns["ebs-kafka"]
}

output "argocd_secret_arns" {
  value = module.secrets_shells.secret_arns
}

output "runner_asg_name" {
  description = "Bootstrap runner Auto Scaling Group. CD scales it up when ARC is not ready and down when it is."
  value       = module.runner.asg_name
}

output "etl_asg_names" {
  description = "ETL Auto Scaling Groups by key (producer, consumer-*). CD starts an instance refresh on each after a new release."
  value = {
    producer             = module.producer_asg.asg_name
    consumer-block       = module.consumer_block_asg.asg_name
    consumer-address     = module.consumer_address_asg.asg_name
    consumer-transaction = module.consumer_transaction_asg.asg_name
  }
}

output "etl_min_healthy" {
  description = "Per ETL group, the MinHealthyPercentage CD uses when it rolls a new release."
  value = {
    producer             = local.producer.refresh_min_healthy_percentage
    consumer-block       = local.consumer_block.refresh_min_healthy_percentage
    consumer-address     = local.consumer_address.refresh_min_healthy_percentage
    consumer-transaction = local.consumer_transaction.refresh_min_healthy_percentage
  }
}

output "scripts_bucket" {
  value = module.scripts_bucket.bucket_name
}

output "db_address" {
  value = module.rds.address
}

output "db_endpoint" {
  description = "Host, port and database name. cd.yml stores it in the db-endpoint secret for the ETL instances."
  value = {
    host = module.rds.address
    port = tostring(module.rds.port)
    name = module.rds.db_name
  }
}

output "db_master_secret_arn" {
  description = "RDS-managed master credentials. Only the migration job reads it."
  value       = module.rds.master_secret_arn
}

output "db_app_secret_arn" {
  description = "Secret the ETL instances read for their own DB user."
  value       = module.db_app_secret.secret_arns[var.db_app_secret_name]
}


output "ecr_registry_host" {
  description = "Your private registry, <account>.dkr.ecr.<region>.amazonaws.com. Layer 2 builds every chart and image path from it."
  value       = module.ecr_cache.registry_host
}

output "ecr_cache_paths" {
  description = "Cache prefix -> registry path (ecr-public, quay, ghcr). Layer 2 pulls charts and images from these instead of the public registries."
  value       = module.ecr_cache.paths
}

output "ecr_cache_pull_policy_arn" {
  description = "IAM policy that lets a role pull through the cache. Layer 2 attaches it to the Karpenter node role and the External Secrets role."
  value       = module.ecr_cache.puller_policy_arn
}