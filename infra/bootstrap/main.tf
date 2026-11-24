data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

# Resolves an assumed-role session ARN back to its IAM role ARN. That stable
# ARN becomes the cluster-admin access entry in the main stack.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  region       = data.aws_region.current.region
  cluster_name = "${var.project}-eks"

  github_oidc_url  = "https://token.actions.githubusercontent.com"
  github_oidc_host = "token.actions.githubusercontent.com"
  github_oidc_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

################################################################################
# Terraform state bucket for the main stack
################################################################################

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tfstate-${local.account_id}"

  # Teardown must not get stuck on old state versions.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.tfstate]
}

################################################################################
# GitHub Actions OIDC provider (one per account per URL)
################################################################################

# Provider v6 needs no thumbprint_list: AWS validates GitHub's certificate itself.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = local.github_oidc_url
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = local.github_oidc_url
}

################################################################################
# CI role: deploy (push images, read the cluster endpoint). main branch only.
################################################################################

data "aws_iam_policy_document" "gha_deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Exact match, no wildcards: only workflow runs on main can deploy.
    # GitHub environments would change sub to ...:environment:x, so none are used.
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = ["${var.github_oidc_sub_prefix}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "${var.project}-gha-deploy"
  description        = "GitHub Actions on main: push images to ECR and deploy to EKS"
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_trust.json
}

data "aws_iam_policy_document" "gha_deploy" {
  # GetAuthorizationToken does not support resource-level permissions.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = ["arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/${var.project}/*"]
  }

  # Only needed by `aws eks update-kubeconfig`; Kubernetes RBAC comes from the
  # access entry in the main stack (Edit, namespace qr-app).
  statement {
    sid       = "EksDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${local.cluster_name}"]
  }
}

resource "aws_iam_role_policy" "gha_deploy" {
  name   = "${var.project}-gha-deploy"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy.json
}

################################################################################
# CI role: plan (read-only terraform plan on PRs and main)
################################################################################

data "aws_iam_policy_document" "gha_plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals with a list = OR across these exact values.
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values = [
        "${var.github_oidc_sub_prefix}:pull_request",
        "${var.github_oidc_sub_prefix}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "gha_plan" {
  name               = "${var.project}-gha-plan"
  description        = "GitHub Actions: read-only terraform plan (run with -lock=false)"
  assume_role_policy = data.aws_iam_policy_document.gha_plan_trust.json
}

resource "aws_iam_role_policy_attachment" "gha_plan_readonly" {
  role       = aws_iam_role.gha_plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess also reads data (object contents, secrets, parameters, table items,
# log events), and this role is assumable from any pull_request run. Plan needs only
# resource metadata plus the main stack's own state, so data reads are denied
# explicitly (an explicit Deny beats the managed Allow). A hand-scoped allow-list
# would be tighter but cannot be tested without AWS and would likely break plan.
data "aws_iam_policy_document" "gha_plan_deny_data" {
  # Every object read except the main stack's own state. Bucket-level reads plan
  # needs (for example s3:GetBucketObjectLockConfiguration) do not match GetObject*.
  statement {
    sid           = "DenyObjectReadsExceptMainState"
    effect        = "Deny"
    actions       = ["s3:GetObject*"]
    not_resources = ["${aws_s3_bucket.tfstate.arn}/main/*"]
  }

  # Plan reads the public EKS AMI parameter (/aws/service/eks/..., used by the node
  # group's use_latest_ami_release_version), so AWS public parameters stay readable.
  statement {
    sid     = "DenyPrivateParameterReads"
    effect  = "Deny"
    actions = ["ssm:GetParameter*"]
    not_resources = [
      "arn:${local.partition}:ssm:*::parameter/aws/service/*",
      "arn:${local.partition}:ssm:*:*:parameter/aws/service/*",
    ]
  }

  statement {
    sid    = "DenySecretAndDataReads"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "kms:Decrypt",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:BatchGetItem",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_plan_deny_data" {
  name   = "${var.project}-gha-plan-deny-data"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.gha_plan_deny_data.json
}
