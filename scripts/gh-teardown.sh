#!/usr/bin/env bash
# make gh-teardown [SCOPE=main|all]
#   main: delete the main-stack variables (CI goes back to skipping deploys) and cancel
#         queued/in-progress app.yml runs.
#   all:  also delete the bootstrap variables.
# Missing variables or a missing repo are not errors (re-runnable).
. "$(dirname "$0")/lib.sh"
need gh jq

scope="${1:-main}"
case "$scope" in main | all) ;; *) die "usage: $0 [main|all]" ;; esac

if ! gh auth status >/dev/null 2>&1; then
  warn "gh not logged in; skipping GitHub variable cleanup (run: gh auth login, then make gh-teardown SCOPE=$scope)"
  exit 0
fi
repo="$(gh_repo)"
if [ -z "$repo" ]; then
  log "no GitHub repo behind 'origin'; nothing to clean"
  exit 0
fi

del_var() {
  if gh variable delete "$1" --repo "$repo" >/dev/null 2>&1; then
    log "deleted variable $1"
  else
    log "variable $1 not present"
  fi
}

for v in EKS_CLUSTER_NAME ECR_REGISTRY ECR_REPO_API ECR_REPO_WEB S3_BUCKET; do del_var "$v"; done

for status in queued in_progress; do
  ids="$(gh run list --repo "$repo" --workflow app.yml --status "$status" --json databaseId -q '.[].databaseId' 2>/dev/null || true)"
  for id in $ids; do
    run gh run cancel "$id" --repo "$repo" || true
  done
done

if [ "$scope" = all ]; then
  for v in AWS_ACCOUNT_ID AWS_REGION TF_STATE_BUCKET AWS_PLAN_ROLE_ARN AWS_DEPLOY_ROLE_ARN CLUSTER_ADMIN_ARN; do del_var "$v"; done
fi
log "gh-teardown ($scope) done"
