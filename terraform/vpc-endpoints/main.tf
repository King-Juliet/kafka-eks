# Private paths from inside the VPC to AWS APIs, so the callers do not go out through the NAT gateway and the internet.
# Today that is Secrets Manager only: the ETL instances read the Kafka address, the database address, the database
# login and the Kafka passwords from it, and the runner and External Secrets read and write it too.
#
# private_dns_enabled makes the normal name (secretsmanager.<region>.amazonaws.com) resolve to the endpoint while
# inside the VPC, so no script, setting or SDK call changes anywhere. Callers outside the VPC (the GitHub-hosted
# runner in layer 1) keep using the public name.

data "aws_region" "current" {}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-vpc-endpoints-"
  description = "AWS API endpoints: HTTPS from inside the VPC only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-vpc-endpoints" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from inside the VPC (ETL instances, runner, cluster nodes and pods)"
}

resource "aws_vpc_endpoint" "this" {
  for_each = toset(var.services)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.this.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.value}" })
}