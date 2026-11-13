# The VPC, built from plain AWS resources (no community module).
# BOTH tiers are created from day one:
#   - public subnets  : nodes live here in phase 1 (no NAT cost)
#   - private subnets : internal NLBs live here; nodes move here in phase 2
# Moving nodes later = flip node_subnet_tier + enable_nat_gateway (see RUNBOOK.txt, NOT PART OF THIS BUILD).

data "aws_region" "current" {}

locals {
  # AZ name => position (0, 1, 2). The position drives the subnet CIDR maths below.
  az_index = { for i, az in var.azs : az => i }

  # /16 VPC + 4 extra bits = /20 subnets. Public use slots 0..7, private use slots 8..15.
  public_subnets  = { for az, i in local.az_index : az => cidrsubnet(var.vpc_cidr, 4, i) }
  private_subnets = { for az, i in local.az_index : az => cidrsubnet(var.vpc_cidr, 4, i + 8) }

  # Karpenter + EKS discover subnets by this tag. Only the tier that hosts nodes gets it.
  discovery_tag = { "karpenter.sh/discovery" = var.name }

  # NAT gateways: none, one shared (in the first AZ), or one per AZ.
  nat_azs = [for i, az in var.azs : az if var.enable_nat_gateway && (!var.single_nat_gateway || i == 0)]

  # Which NAT gateway serves the private subnet of each AZ.
  nat_az_for = { for az in var.azs : az => var.single_nat_gateway ? var.azs[0] : az }
}

# ------------------------------------------------------------------ VPC + internet gateway

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # EKS needs both: nodes and pods resolve names, and the private API endpoint uses a DNS name.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

# Lock down the default security group: with no rules listed, Terraform removes all of them.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-locked" })
}

# ------------------------------------------------------------------ subnets

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(
    var.tags,
    {
      Name                                = "${var.name}-public-${each.key}"
      "kubernetes.io/role/elb"            = "1"
      "kubernetes.io/cluster/${var.name}" = "shared"
    },
    var.node_subnet_tier == "public" ? local.discovery_tag : {}
  )
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = merge(
    var.tags,
    {
      Name                                = "${var.name}-private-${each.key}"
      "kubernetes.io/role/internal-elb"   = "1"
      "kubernetes.io/cluster/${var.name}" = "shared"
    },
    var.node_subnet_tier == "private" ? local.discovery_tag : {}
  )
}

# ------------------------------------------------------------------ routing: public tier

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ------------------------------------------------------------------ NAT (only when enable_nat_gateway = true)

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

# ------------------------------------------------------------------ routing: private tier (one table per AZ)

resource "aws_route_table" "private" {
  for_each = local.private_subnets

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-private-${each.key}" })
}

resource "aws_route" "private_nat" {
  for_each = { for az, cidr in local.private_subnets : az => cidr if var.enable_nat_gateway }

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_az_for[each.key]].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ------------------------------------------------------------------ S3 gateway endpoint (free)
# Image layers (ECR) and Kafka client downloads stay off the NAT/internet path.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], [for rt in aws_route_table.private : rt.id])

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

# ------------------------------------------------------------------ flow logs -> CloudWatch (when enable_flow_logs = true)

resource "aws_cloudwatch_log_group" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc-flow-logs/${var.name}"
  retention_in_days = var.flow_log_retention_days

  tags = var.tags
}

data "aws_iam_policy_document" "flow_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_write" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume[0].json

  tags = var.tags
}

resource "aws_iam_role_policy" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow[0].id
  policy = data.aws_iam_policy_document.flow_write[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn             = aws_iam_role.flow[0].arn
  max_aggregation_interval = 60

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}