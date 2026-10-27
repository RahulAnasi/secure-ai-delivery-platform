locals {
  deployment_artifact = jsondecode(
    file("${path.module}/../../../../deploy/aws/dev/artifact.json")
  )

  delivery_bucket_name = "secure-ai-delivery-${data.aws_caller_identity.current.account_id}-ap-south-1-dev"

  artifact_object_key = "artifacts/${local.deployment_artifact.archive_sha256}/${local.deployment_artifact.archive_name}"
}

resource "aws_s3_bucket" "delivery" {
  bucket        = local.delivery_bucket_name
  force_destroy = false

  tags = {
    Name = "${local.name_prefix}-delivery"
  }
}

resource "aws_s3_bucket_public_access_block" "delivery" {
  bucket = aws_s3_bucket.delivery.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "delivery" {
  bucket = aws_s3_bucket.delivery.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "delivery" {
  bucket = aws_s3_bucket.delivery.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "delivery_transport" {
  statement {
    sid     = "DenyUnencryptedTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.delivery.arn,
      "${aws_s3_bucket.delivery.arn}/*"
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "delivery" {
  bucket = aws_s3_bucket.delivery.id
  policy = data.aws_iam_policy_document.delivery_transport.json
}