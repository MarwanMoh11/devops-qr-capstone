#!/usr/bin/env bash
# make bootstrap: apply infra/bootstrap (local state): state bucket, GitHub OIDC
# provider, CI roles. Then copy its outputs to GitHub variables. Re-runnable.
# Keep infra/bootstrap/terraform.tfstate: losing it means the aws-cli fallback in nuke.
. "$(dirname "$0")/lib.sh"
preflight_cloud

log "account $(aws_account_id), region $AWS_REGION, repo $(gh_repo)"
log "create_github_oidc_provider=$(oidc_toggle) (false only when one already exists outside this state)"
run terraform -chdir="$TF_BOOT" init -input=false
tf_boot apply -auto-approve
"$ROOT/scripts/gh-setup.sh"
