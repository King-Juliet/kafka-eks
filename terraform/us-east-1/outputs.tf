output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "bastion_instance_id" {
  value = module.bastion.instance_id
}

output "bastion_public_ip" {
  description = "Elastic IP of the bastion: the only address allowed on the public Kubernetes API."
  value       = module.bastion.public_ip
}

output "api_tunnel_command" {
  description = "Opens the tunnel from this machine to the Kubernetes API through the bastion. Run it in its own terminal and leave it running. Terraform (once the cluster exists) and kubectl both need it."
  value       = "aws ssm start-session --region ${var.region} --target ${module.bastion.instance_id} --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters host=$(dig +short A ${local.api_server_name} | grep -E '^[0-9.]+$' | head -n 1),portNumber=443,localPortNumber=${var.api_tunnel_port}"
}

output "update_kubeconfig_command" {
  description = "Points kubectl at the cluster through the tunnel. Run with: eval \"$(terraform output -raw update_kubeconfig_command)\""
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} && kubectl config set-cluster ${module.eks.cluster_arn} --server=${local.api_tunnel_url} --tls-server-name=${local.api_server_name}"
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

output "kafka_ebs_kms_key_arn" {
  value = module.kms.key_arns["ebs-kafka"]
}

output "argocd_secret_arns" {
  value = module.secrets_shells.secret_arns
}

output "karpenter_queue_name" {
  value = module.karpenter.queue_name
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "kafka_storage_class" {
  value = module.kafka_storage.storage_class_name
}

output "kafka_client_asg_names" {
  description = "Empty (null) until kafka_bootstrap_servers is set."
  value       = one(module.kafka_clients[*].asg_names)
}

output "next_steps" {
  value = <<-EOT
    Cluster and controllers are up. Next (the tunnel terminal must still be open):
      1. eval "$(terraform output -raw update_kubeconfig_command)"
      2. kubectl get nodepools,ec2nodeclasses
      3. Install Argo CD yourself (your method), then apply gitops/bootstrap/*
      4. See RUNBOOK.txt, phase 2.
  EOT
}