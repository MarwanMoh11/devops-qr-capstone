# Names map 1:1 to GitHub repository variables (scripts/gh-setup.sh).

output "aws_account_id" {
  description = "AWS_ACCOUNT_ID"
  value       = local.account_id
}

output "aws_region" {
  description = "AWS_REGION"
  value       = local.region
}

output "tf_state_bucket" {
  description = "TF_STATE_BUCKET: backend bucket for infra/main"
  value       = aws_s3_bucket.tfstate.bucket
}

output "gha_plan_role_arn" {
  description = "AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.gha_plan.arn
}

output "gha_deploy_role_arn" {
  description = "AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.gha_deploy.arn
}

output "admin_principal_arn" {
  description = "CLUSTER_ADMIN_ARN: IAM principal that ran bootstrap (role ARN, not the session ARN)"
  value       = data.aws_iam_session_context.current.issuer_arn
}
