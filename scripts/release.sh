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

# The workflow builds origin/main, not this checkout: refuse if they differ.
[ -z "$(git -C "$ROOT" status --porcelain)" ] \
  || die "uncommitted changes would not be deployed. Commit and push them first"
run git -C "$ROOT" fetch -q origin main
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] \
  || die "local HEAD differs from origin/main, so CI would deploy something else. Run: git push (or git pull)"

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
# gh run watch gives up on a transient GitHub API error (seen: HTTP 500) while the run
# carries on, so keep watching until GitHub reports the run's own result.
result=""
for _ in $(seq 1 60); do
  gh run watch "$id" --repo "$repo" --interval 10 || true
  result="$(gh run view "$id" --repo "$repo" --json status,conclusion \
    -q 'select(.status == "completed") | .conclusion' 2>/dev/null || true)"
  [ -n "$result" ] && break
  sleep 10
done
[ "$result" = success ] || die "run $id: ${result:-no result from GitHub}. See https://github.com/$repo/actions/runs/$id"
log "release passed"
