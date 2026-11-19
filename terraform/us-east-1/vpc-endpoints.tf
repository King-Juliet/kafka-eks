# Private path to AWS APIs from inside the VPC, so the ETL instances never use the NAT gateway to reach AWS.
#   secretsmanager                      Kafka address, database address and logins, Kafka passwords, cluster CA
#   logs                                the CloudWatch agent ships the ETL log file
#   monitoring                          the lag publisher writes the ConsumerLag metric
#   ssm, ssmmessages, ec2messages       Session Manager and Run Command (scripts/verify.sh)
# S3 (release downloads, package repositories) already has its own free gateway endpoint in the VPC module.
# The one thing that still needs the NAT gateway is the producer calling the Blockstream API (not an AWS service).
module "vpc_endpoints" {
  source = "../vpc-endpoints"

  name       = var.cluster_name
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = var.vpc_cidr
  subnet_ids = module.vpc.private_subnet_ids
  services   = ["secretsmanager", "logs", "monitoring", "ssm", "ssmmessages", "ec2messages"]
  tags       = local.tags
}