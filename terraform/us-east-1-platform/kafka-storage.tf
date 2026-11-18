module "kafka_storage" {
  source = "../kafka-storage"

  kms_key_arn = local.l1.kafka_ebs_kms_key_arn
}