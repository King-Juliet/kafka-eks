# Bootstrap runner: one small EC2 instance INSIDE the VPC that runs GitHub Actions jobs which must reach the
# private Kubernetes API. It exists for two reasons:
#   1. the very first run, before the cluster (and so ARC, the in-cluster runners) exists, and
#   2. a fallback whenever ARC is unhealthy.
# Once ARC is up, CD scales this group to 0 (no cost, no idle machine with network access).
#
# Each runner process takes ONE job and then removes itself (ephemeral); a small loop registers a fresh one.
# No SSH, no key pair, no inbound rules. Use SSM Session Manager if you ever need a shell.

data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  role_name = "${var.name}-ci-runner"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# The instance role is deliberately small. Jobs get their AWS permissions by assuming the GitHub OIDC deploy
# role (main branch only), not from the machine.
resource "aws_iam_role" "this" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "read_token" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.auth_secret_arn]
  }
}

resource "aws_iam_role_policy" "read_token" {
  name   = "read-runner-registration-token"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read_token.json
}

resource "aws_iam_instance_profile" "this" {
  name = local.role_name
  role = aws_iam_role.this.name
  tags = var.tags
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-ci-runner-"
  description = "CI runner: no inbound, all outbound"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-ci-runner" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "GitHub, AWS APIs, package mirrors, the private Kubernetes API"
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-ci-runner-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.this.id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    region         = data.aws_region.current.region
    repo           = var.github_repo
    labels         = join(",", var.labels)
    auth_secret_id = var.auth_secret_arn
    runner_version = var.runner_version
    runner_sha256  = var.runner_sha256
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-ci-runner", Role = "ci-runner" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-ci-runner"
  min_size            = 0
  max_size            = 1
  desired_capacity    = var.initial_desired_capacity
  vpc_zone_identifier = var.subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = "${var.name}-ci-runner", Role = "ci-runner" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # The pipeline owns the live size (up for bootstrap/fallback, down once ARC is ready).
    ignore_changes = [desired_capacity]
  }
}