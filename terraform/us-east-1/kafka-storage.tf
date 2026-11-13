module "kafka_storage" {
  source = "../kafka-storage"

  kms_key_arn = module.kms.key_arns["ebs-kafka"]

  depends_on = [module.eks]
}