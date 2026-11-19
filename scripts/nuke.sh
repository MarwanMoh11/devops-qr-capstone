#!/usr/bin/env bash
# make nuke: back to $0. infra-down, then the bootstrap stack, then every GitHub
# variable, then verify-clean (exits non-zero if anything billable is left).
. "$(dirname "$0")/lib.sh"
require_aws
need terraform jq

"$ROOT/scripts/infra-down.sh"

log "step 6/7: bootstrap stack"
# The state bucket (force_destroy) holds the main stack's state. Deleting it while
# the cluster or any main resource remains would orphan billing resources.
require_main_stack_gone
if boot_state_exists; then
  # The value only matters for apply; destroy removes whatever the state holds.
  GITHUB_REPO="$(gh_repo)"
  export GITHUB_REPO="${GITHUB_REPO:-unknown/$GH_REPO_NAME}"
  run terraform -chdir="$TF_BOOT" init -input=false
  tf_boot destroy -auto-approve
else
  warn "no bootstrap state; using the aws-cli fallback (gotcha 24)"
  acct="$(aws_account_id)"
  bucket="$PROJECT-tfstate-$acct"
  bucket_found="$(bucket_exists "$bucket")"
  if [ "$bucket_found" = true ]; then
    # Versioned bucket: delete every version and delete marker, 1000 at a time.
    while :; do
      batch="$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 --output json \
        | jq -c '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId})), Quiet: true}')"
      [ "$(jq '.Objects | length' <<<"$batch")" -gt 0 ] || break
      run aws s3api delete-objects --bucket "$bucket" --delete "$batch" >/dev/null
    done
    run aws s3 rb "s3://$bucket"
  fi
  for role in "$PROJECT-gha-deploy" "$PROJECT-gha-plan"; do
    aws iam get-role --role-name "$role" >/dev/null 2>&1 || continue
    for p in $(aws iam list-attached-role-policies --role-name "$role" --output json | jq -r '.AttachedPolicies[].PolicyArn'); do
      run aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
    done
    for p in $(aws iam list-role-policies --role-name "$role" --output json | jq -r '.PolicyNames[]'); do
      run aws iam delete-role-policy --role-name "$role" --policy-name "$p"
    done
    run aws iam delete-role --role-name "$role"
  done
  # Only delete the GitHub OIDC provider if this project created it (Project tag).
  for arn in $(aws iam list-open-id-connect-providers --output json \
    | jq -r '.OpenIDConnectProviderList[].Arn | select(endswith("/token.actions.githubusercontent.com"))'); do
    if aws iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" --output json \
      | jq -e --arg p "$PROJECT" '.Tags[]? | select(.Key == "Project" and .Value == $p)' >/dev/null; then
      run aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn"
    else
      log "keeping $arn (not tagged Project=$PROJECT, so it predates this project)"
    fi
  done
fi

log "step 7/7: GitHub variables, then verify-clean"
"$ROOT/scripts/gh-teardown.sh" all
"$ROOT/scripts/verify-clean.sh"
