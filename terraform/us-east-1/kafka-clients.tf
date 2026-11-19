# What the producer and the three consumers have in common. Each client has its own file (kafka-producer.tf,
# kafka-consumer-block.tf, kafka-consumer-address.tf, kafka-consumer-transaction.tf) with its own role, its own
# Auto Scaling Group and its own scaling, so one of them can change without touching the others.
#
# They run OUTSIDE the cluster, in private subnets, and reach Kafka through the internal NLB listener (9094: TLS +
# SCRAM-SHA-512) and PostgreSQL on RDS. The code is NOT baked into an image: CD uploads each release to S3 and moves a
# pointer (a Secrets Manager secret); an instance copies the release at boot (templates/user-data.sh.tftpl). The Kafka
# address, the database address and the release pointer are Secrets Manager secrets (config-secrets.tf) that CD fills in
# later, so there is no "set a variable after Kafka is up" step. No SSH: use SSM Session Manager.

# The newest Amazon Linux 2023 image. A newer image changes the launch template, which rolls the instances.
data "aws_ssm_parameter" "etl_al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  etl_metric_namespace   = "KafkaEks" # the lag publisher writes ConsumerLag here
  etl_partition_count    = 5          # partitions of the topics the consumers read (gitops/kafka/base/topics.yaml)
  etl_log_retention_days = 30         # ASSUMPTION: 30 days of ETL logs in CloudWatch
  etl_ca_secret_id       = "/kafka/cluster/ca-crt"
  etl_lag_user           = "lag-monitor" # read-only Kafka user of the lag publisher
  etl_alarm_actions      = var.alarm_topic_arn == null ? [] : [var.alarm_topic_arn]

  etl_secret_arn_prefix = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:"

  # The part of every client's boot script that is the same for all of them. Each client file adds its own group_key,
  # kafka_user, script, run_lag_publisher and log_group.
  etl_user_data_common = {
    region                = var.region
    bucket                = module.scripts_bucket.bucket_name
    release_secret_id     = local.config_secret_names.clients_release
    bootstrap_secret_id   = local.config_secret_names.kafka_bootstrap
    db_endpoint_secret_id = local.config_secret_names.db_endpoint
    db_secret_id          = module.db_app_secret.secret_arns[var.db_app_secret_name]
    ca_secret_id          = local.etl_ca_secret_id
    lag_user              = local.etl_lag_user
    render_env_script     = file("${path.module}/templates/render-env.sh")
  }
}

# One security group for all four: no inbound, all outbound. RDS lets it in on 5432 (rds.tf).
resource "aws_security_group" "etl_clients" {
  name_prefix = "${var.cluster_name}-etl-clients-"
  description = "ETL ASG instances: no inbound, all outbound"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, { Name = "${var.cluster_name}-etl-clients" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "etl_clients_all" {
  security_group_id = aws_security_group.etl_clients.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Kafka NLB, RDS, AWS APIs (through the VPC endpoints), and the Blockstream API (producer, through NAT)"
}

# What every client may read. Each client file adds its own Kafka password (and the producer adds the lag extras).
data "aws_iam_policy_document" "etl_common" {
  statement {
    sid     = "ReadSharedSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "${local.etl_secret_arn_prefix}${local.etl_ca_secret_id}-*",
      module.db_app_secret.secret_arns[var.db_app_secret_name],
    ]
  }

  statement {
    sid     = "ReadConfigSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "${local.etl_secret_arn_prefix}${local.config_secret_names.clients_release}-*",
      "${local.etl_secret_arn_prefix}${local.config_secret_names.kafka_bootstrap}-*",
      "${local.etl_secret_arn_prefix}${local.config_secret_names.db_endpoint}-*",
    ]
  }

  statement {
    sid       = "ReadReleases"
    actions   = ["s3:GetObject"]
    resources = ["${module.scripts_bucket.bucket_arn}/releases/*"]
  }

  statement {
    sid       = "ListReleases"
    actions   = ["s3:ListBucket"]
    resources = [module.scripts_bucket.bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["releases/*"]
    }
  }
}