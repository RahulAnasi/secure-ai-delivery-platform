data "aws_secretsmanager_secret" "model_key" {
  name = local.deployment_artifact.runtime_secret_id
}

data "aws_iam_policy_document" "runtime_read" {
  statement {
    sid     = "DownloadSelectedArtifact"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    resources = [
      "${aws_s3_bucket.delivery.arn}/${local.artifact_object_key}"
    ]
  }

  statement {
    sid     = "ReadSelectedModelKey"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      data.aws_secretsmanager_secret.model_key.arn
    ]
  }
}

resource "aws_iam_role_policy" "runtime_read" {
  name   = "${local.name_prefix}-runtime-read"
  role   = aws_iam_role.dev_ec2.id
  policy = data.aws_iam_policy_document.runtime_read.json
}