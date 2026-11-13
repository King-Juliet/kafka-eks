# StorageClass for Kafka data volumes: gp3, encrypted with our CMK, zonal binding, expandable,
# and Retain so deleting a PVC never deletes the EBS volume (Kafka data) by accident.

resource "kubernetes_storage_class_v1" "this" {
  metadata {
    name = var.name
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type                        = "gp3"
    encrypted                   = "true"
    kmsKeyId                    = var.kms_key_arn
    iops                        = tostring(var.iops)
    throughput                  = tostring(var.throughput)
    "csi.storage.k8s.io/fstype" = "xfs"
  }
}