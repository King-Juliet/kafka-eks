# Jump host. Its Elastic IP is the only address allowed to reach the public Kubernetes API (see eks.tf).
# You reach the bastion itself with Systems Manager Session Manager: no SSH, no key pair, no inbound rules.
module "bastion" {
  source = "../bastion"

  name          = var.cluster_name
  vpc_id        = module.vpc.vpc_id
  subnet_id     = module.vpc.public_subnet_ids[0] # first public subnet
  instance_type = var.bastion_instance_type
  tags          = local.tags

  # The Elastic IP can only attach once the internet gateway and public routes exist.
  depends_on = [module.vpc]
}