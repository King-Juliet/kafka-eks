# A launch template and an Auto Scaling Group. Nothing else: no IAM role, no alarms, no scaling policies, nothing
# about Kafka. The caller brings the image, the security group, the instance profile and the boot script, and adds
# whatever scaling it wants on top (see the lag-scaling module).
#
# Fixed on purpose: IMDSv2 only, no public IP, encrypted gp3 root volume, EC2 health checks.

locals {
  instance_tags = merge(var.tags, var.instance_tags, { Name = var.name })
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = var.image_id
  instance_type = var.instance_type
  user_data     = var.user_data == null ? null : base64encode(var.user_data)

  iam_instance_profile {
    name = var.instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = var.security_group_ids
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

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                = var.name
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_size
  vpc_zone_identifier = var.subnet_ids

  health_check_type         = "EC2"
  health_check_grace_period = var.health_check_grace_period

  enabled_metrics     = var.enabled_metrics
  metrics_granularity = "1Minute"

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # A new launch template version (new image or new boot script) replaces the instances, a few at a time.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = var.refresh_min_healthy_percentage
      instance_warmup        = var.refresh_instance_warmup
    }
  }

  dynamic "tag" {
    for_each = local.instance_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity] # scaling policies own the live value
  }
}