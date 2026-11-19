# Names map 1:1 to GitHub repository variables (scripts/gh-setup.sh) except the
# last two, which only scripts and verify-clean use.

output "cluster_name" {
  description = "EKS_CLUSTER_NAME"
  value       = module.eks.cluster_name
}

output "ecr_registry" {
  description = "ECR_REGISTRY: <account>.dkr.ecr.<region>.amazonaws.com"
  value       = split("/", aws_ecr_repository.this["api"].repository_url)[0]
}

output "ecr_repo_api" {
  description = "ECR_REPO_API"
  value       = aws_ecr_repository.this["api"].name
}

output "ecr_repo_web" {
  description = "ECR_REPO_WEB"
  value       = aws_ecr_repository.this["web"].name
}

output "s3_bucket_name" {
  description = "S3_BUCKET"
  value       = aws_s3_bucket.qr.bucket
}

output "api_pod_role_arn" {
  description = "IAM role assumed by qr-app/qr-api through Pod Identity"
  value       = module.api_s3_pod_identity.iam_role_arn
}

output "vpc_id" {
  description = "VPC ID (used by verify-clean)"
  value       = module.vpc.vpc_id
}
