#!/usr/bin/env bash
# make release: run the app pipeline (test -> build linux/amd64 -> push to ECR ->
# deploy -> smoke test) on main in GitHub Actions and wait for it to finish.
. "$(dirname "$0")/lib.sh"
require_gh
need jq

repo="$(gh_repo)"
[ -n "$repo" ] || die "no GitHub repo behind 'origin'. Run: make gh-repo"
[ -n "$(gh variable list --repo "$repo" --json name -q '.[] | select(.name=="EKS_CLUSTER_NAME") | .name')" ] \
  || die "repo variable EKS_CLUSTER_NAME is not set, so CI would skip the deploy. Run: make infra-up (or make gh-setup)"

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run gh workflow run app.yml --repo "$repo" --ref main

newest_run() {
  gh run list --repo "$repo" --workflow app.yml --branch main --event workflow_dispatch \
    --limit 5 --json databaseId,createdAt \
    -q "[.[] | select(.createdAt >= \"$started\")] | sort_by(.createdAt) | last | .databaseId // empty"
}
id=""
for _ in $(seq 1 30); do
  id="$(newest_run)"
  [ -n "$id" ] && break
  sleep 3
done
[ -n "$id" ] || die "could not find the dispatched app.yml run (check: gh run list --workflow app.yml)"
log "watching run $id: https://github.com/$repo/actions/runs/$id"
run gh run watch "$id" --repo "$repo" --exit-status
