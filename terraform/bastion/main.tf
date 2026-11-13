# A small jump host. Its Elastic IP is the ONLY address allowed to reach the public Kubernetes API.
#
# No SSH, no key pair, no inbound rules at all. You reach the bastion with AWS Systems Manager Session
# Manager (IAM-authenticated, over HTTPS). The bastion connects OUT to the EKS endpoint across the internet,
# so the API sees the Elastic IP as the source address. That is the address the region folder (eks.tf) puts
# on the cluster's allowlist.
#
#   1. IAM       : role + instance profile so the SSM agent can register
#   2. Network   : security group (no inbound rules, HTTPS out only)
#   3. Instance  : Amazon Linux 2023, IMDSv2 only, encrypted root volume
#   4. Elastic IP: the fixed address that goes on the allowlist

data "aws_partition" "current" {}

# AWS publishes the current Amazon Linux 2023 AMI id under this public SSM parameter (SSM agent is preinstalled).
data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# ------------------------------------------------------------------ 1. IAM

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-bastion"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = var.tags
}

# The AWS-managed policy the SSM agent needs. The bastion gets no other AWS permissions (not even EKS).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-bastion"
  role = aws_iam_role.this.name

  tags = var.tags
}

# ------------------------------------------------------------------ 2. network

resource "aws_security_group" "this" {
  name        = "${var.name}-bastion"
  description = "Bastion: no inbound rules, HTTPS out only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-bastion" })
}

# The only rule there is. Port 443 covers Systems Manager, the EKS API and package downloads.
# DNS goes to the VPC resolver, which security groups do not filter.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS out: Systems Manager, the EKS API, package downloads"
}

# ------------------------------------------------------------------ 3. the instance

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.ami.insecure_value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name

  # IMDSv2 only, and one network hop: containers on the host cannot read the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gib
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name}-bastion" })

  lifecycle {
    # "Latest" moves every few weeks. Without this, Terraform would replace the bastion (and drop your
    # tunnel) the day a new image is published. To refresh it on purpose, use -replace on this resource (README).
    ignore_changes = [ami]
  }
}

# ------------------------------------------------------------------ 4. Elastic IP

# The address survives a replaced instance, so the cluster allowlist never changes.
resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.this.id

  tags = merge(var.tags, { Name = "${var.name}-bastion" })
}