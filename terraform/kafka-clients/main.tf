# Producers and consumers run in Auto Scaling Groups OUTSIDE the cluster, talking to Kafka through
# the internal NLB listener (port 9094: TLS + SCRAM-SHA-512). No SSH: use SSM Session Manager.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name_prefix}-kafka-clients-"
  description = "Kafka client ASG instances: no inbound, all outbound"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka-clients" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Outbound (Kafka NLB, Secrets Manager, package mirrors)"
}

# One role per group so each can only read ITS Kafka user's password (+ the shared CA cert).
resource "aws_iam_role" "this" {
  for_each = var.groups

  name               = "${var.name_prefix}-kafka-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = var.groups

  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "secrets" {
  for_each = var.groups

  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:/kafka/clients/${each.value.kafka_user}*",
      "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.ca_secret_id}*",
    ]
  }
}

resource "aws_iam_role_policy" "secrets" {
  for_each = var.groups

  name   = "read-kafka-credentials"
  role   = aws_iam_role.this[each.key].id
  policy = data.aws_iam_policy_document.secrets[each.key].json
}

resource "aws_iam_instance_profile" "this" {
  for_each = var.groups

  name = "${var.name_prefix}-kafka-${each.key}"
  role = aws_iam_role.this[each.key].name
  tags = var.tags
}

resource "aws_launch_template" "this" {
  for_each = var.groups

  name_prefix   = "${var.name_prefix}-kafka-${each.key}-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = each.value.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.this[each.key].name
  }

  network_interfaces {
    associate_public_ip_address = var.assign_public_ip
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
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    region             = var.region
    kafka_download_url = var.kafka_download_url
    kafka_user         = each.value.kafka_user
    password_secret_id = "/kafka/clients/${each.value.kafka_user}"
    ca_secret_id       = var.ca_secret_id
    bootstrap_servers  = var.bootstrap_servers
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name_prefix}-kafka-${each.key}", KafkaRole = each.key })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  for_each = var.groups

  name                = "${var.name_prefix}-kafka-${each.key}"
  min_size            = each.value.min_size
  max_size            = each.value.max_size
  desired_capacity    = each.value.desired_size
  vpc_zone_identifier = var.subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this[each.key].id
    version = aws_launch_template.this[each.key].latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = "${var.name_prefix}-kafka-${each.key}", KafkaRole = each.key })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity] # let scaling policies own the live value
  }
}

# Simple CPU-based scaling. For consumers you will eventually scale on consumer-group lag instead
# (Kafka Exporter metric -> CloudWatch/Prometheus -> custom-metric policy).
resource "aws_autoscaling_policy" "cpu" {
  for_each = var.groups

  name                   = "cpu-target-60"
  autoscaling_group_name = aws_autoscaling_group.this[each.key].name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}