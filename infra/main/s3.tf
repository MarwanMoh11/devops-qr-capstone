resource "aws_s3_bucket" "qr" {
  bucket        = "${var.project}-qrcodes-${local.account_id}"
  force_destroy = true # teardown must not fail on leftover QR images
}

resource "aws_s3_bucket_ownership_controls" "qr" {
  bucket = aws_s3_bucket.qr.id

  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

# The bucket stays private: the API streams images to the browser (no presigned URLs).
resource "aws_s3_bucket_public_access_block" "qr" {
  bucket = aws_s3_bucket.qr.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "qr" {
  bucket = aws_s3_bucket.qr.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "qr" {
  bucket = aws_s3_bucket.qr.id

  rule {
    id     = "expire-qr-codes"
    status = "Enabled"

    filter {
      prefix = "qr_codes/"
    }

    expiration {
      days = var.qr_object_expiry_days
    }
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "qr_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.qr.arn,
      "${aws_s3_bucket.qr.arn}/*",
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

resource "aws_s3_bucket_policy" "qr" {
  bucket = aws_s3_bucket.qr.id
  policy = data.aws_iam_policy_document.qr_tls_only.json

  # Avoid racing the public-access block on create.
  depends_on = [aws_s3_bucket_public_access_block.qr]
}
