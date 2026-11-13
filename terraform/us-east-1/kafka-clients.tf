# Producer / consumer Auto Scaling Groups. Created only once Kafka is running and you set
# kafka_bootstrap_servers in terraform.tfvars (RUNBOOK step 16); until then nothing is built.
module "kafka_clients" {
  count  = var.kafka_bootstrap_servers == null ? 0 : 1
  source = "../kafka-clients"

  name_prefix       = var.cluster_name
  region            = var.region
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.node_subnet_ids
  assign_public_ip  = local.nodes_in_public_subnets
  bootstrap_servers = var.kafka_bootstrap_servers
  groups            = var.kafka_client_groups
  tags              = local.tags
}