# API pods (ServiceAccount qr-app/qr-api) -> S3, via EKS Pod Identity.
module "api_s3_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name            = "${var.project}-api-s3"
  use_name_prefix = false # exact role name from the contract

  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "QrObjectsReadWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject", "s3:GetObject"]
      resources = ["${aws_s3_bucket.qr.arn}/qr_codes/*"]
    },
    {
      # ListBucket lets HeadBucket succeed (readiness probe) and makes a
      # missing key return 404 instead of 403.
      sid       = "QrBucketList"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.qr.arn]
    },
  ]

  associations = {
    qr_api = {
      cluster_name    = module.eks.cluster_name
      namespace       = "qr-app"
      service_account = "qr-api"
    }
  }
}

# CloudWatch agent role. No association here: the amazon-cloudwatch-observability
# add-on block (addons.tf) creates it. This module must not reference module.eks,
# because its role ARN is an input to that add-on.
module "cloudwatch_agent_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name            = "${var.project}-cloudwatch-agent"
  use_name_prefix = false

  attach_aws_cloudwatch_observability_policy = true
}
