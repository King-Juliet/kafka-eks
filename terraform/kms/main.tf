# Customer-managed keys with rotation on. Default key policy (account root) so IAM policies
# on the consuming roles decide who can use them.

resource "aws_kms_key" "this" {
  for_each = var.keys

  description             = each.value
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_kms_alias" "this" {
  for_each = var.keys

  name          = "alias/${var.name_prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}