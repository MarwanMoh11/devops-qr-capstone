#!/usr/bin/env bash
# make gh-setup: copy Terraform outputs into GitHub repo variables (§5.4, 1:1).
# Sets every variable whose output exists; skips a stack that has no state yet.
# No secrets: CI authenticates to AWS with OIDC only.
. "$(dirname "$0")/lib.sh"
require_gh
need terraform jq

repo="$(gh_repo)"
[ -n "$repo" ] || die "no GitHub repo behind 'origin'. Run: make gh-repo"

set_var() { # <GH_VARIABLE> <value>
  if [ -n "$2" ]; then
    run gh variable set "$1" --repo "$repo" --body "$2"
  else
    warn "skipping $1 (output empty)"
  fi
}

# output <json> <name>
output() { jq -r --arg k "$2" '.[$k].value // empty' <<<"$1"; }

boot="$(terraform -chdir="$TF_BOOT" output -json 2>/dev/null || echo '{}')"
if [ "$boot" = '{}' ] || [ -z "$boot" ]; then
  warn "bootstrap stack has no outputs yet (run: make bootstrap)"
else
  set_var AWS_ACCOUNT_ID "$(output "$boot" aws_account_id)"
  set_var AWS_REGION "$(output "$boot" aws_region)"
  set_var TF_STATE_BUCKET "$(output "$boot" tf_state_bucket)"
  set_var AWS_PLAN_ROLE_ARN "$(output "$boot" gha_plan_role_arn)"
  set_var AWS_DEPLOY_ROLE_ARN "$(output "$boot" gha_deploy_role_arn)"
  set_var CLUSTER_ADMIN_ARN "$(output "$boot" admin_principal_arn)"
fi

main="$(terraform -chdir="$TF_MAIN" output -json 2>/dev/null || echo '{}')"
if [ "$main" = '{}' ] || [ -z "$main" ]; then
  warn "main stack has no outputs (not applied, or not initialised here); main variables not set"
else
  set_var EKS_CLUSTER_NAME "$(output "$main" cluster_name)"
  set_var ECR_REGISTRY "$(output "$main" ecr_registry)"
  set_var ECR_REPO_API "$(output "$main" ecr_repo_api)"
  set_var ECR_REPO_WEB "$(output "$main" ecr_repo_web)"
  set_var S3_BUCKET "$(output "$main" s3_bucket_name)"
fi
run gh variable list --repo "$repo"
