output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

# Subnet lists keep the order of var.azs.
output "public_subnet_ids" {
  value = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  value = [for az in var.azs : aws_subnet.private[az].id]
}

# The subnets nodes (managed node group + Karpenter) will use.
output "node_subnet_ids" {
  value = var.node_subnet_tier == "public" ? [for az in var.azs : aws_subnet.public[az].id] : [for az in var.azs : aws_subnet.private[az].id]
}