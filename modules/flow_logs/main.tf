###############################################################################
# Central Flow Logs Infrastructure (Simulated Security Account)
# In a real multi-account org this bucket lives in a dedicated security account.
# The bucket policy is written to accept delivery from multiple AWS accounts,
# making it promotion-ready without changes.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

###############################################################################
# KMS Key for flow log encryption at rest (HIPAA requirement)
###############################################################################

resource "aws_kms_key" "flow_logs" {
  description             = "KMS key for VPC flow logs - ${var.prefix}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowFlowLogsServiceEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3ServiceEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.prefix}-flow-logs-key"
    Purpose = "flow-log-encryption"
  })
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${var.prefix}-flow-logs"
  target_key_id = aws_kms_key.flow_logs.key_id
}

###############################################################################
# S3 Bucket
###############################################################################

resource "aws_s3_bucket" "flow_logs" {
  bucket        = "${var.prefix}-vpc-flow-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name           = "${var.prefix}-vpc-flow-logs"
    Purpose        = "central-flow-log-archive"
    Sensitivity    = "security-logs"
    HIPAARetention = "7-years"
  })
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.flow_logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# Lifecycle: move to IA after 90d, Glacier after 365d, expire after 7 years
# HIPAA requires audit logs for a minimum of 6 years; 7 years provides buffer
###############################################################################

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    id     = "flow-log-lifecycle"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = 2557 # 7 years
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

###############################################################################
# Bucket Policy
# Allows delivery.logs.amazonaws.com to write flow logs from any account
# listed in var.source_account_ids. Falls back to current account if empty.
###############################################################################

locals {
  source_accounts = length(var.source_account_ids) > 0 ? var.source_account_ids : [data.aws_caller_identity.current.account_id]
}

data "aws_iam_policy_document" "flow_logs_bucket" {
  # Allow the flow logs delivery service to check bucket ACL
  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.flow_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = local.source_accounts
    }
  }

  # Allow the flow logs delivery service to write objects
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow_logs.arn}/vpc-flow-logs/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = local.source_accounts
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [for account in local.source_accounts : "arn:aws:logs:${data.aws_region.current.name}:${account}:*"]
    }
  }

  # Deny all non-HTTPS access (encryption in transit)
  statement {
    sid    = "DenyNonSSLRequests"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.flow_logs.arn, "${aws_s3_bucket.flow_logs.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Deny unencrypted object uploads
  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow_logs.arn}/*"]

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

resource "aws_s3_bucket_policy" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.flow_logs]
}
