#!/usr/bin/env bash
# make gh-repo: create the private GitHub repo from this checkout and push main.
# With no AWS variables set yet, every AWS job in CI is skipped, so the run is green.
. "$(dirname "$0")/lib.sh"
require_gh

# gh repo create --push and git push send commits only. Uncommitted files (for
# example the workflows) would be missing on main and make up's release step fails.
dirty="$(git -C "$ROOT" status --porcelain)"
[ -z "$dirty" ] || die "the working tree has uncommitted changes; commit them first, e.g.
  git add -A && git commit -m 'Initial commit'
then re-run: make gh-repo. Uncommitted:
$dirty"

if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  log "origin already set: $(git -C "$ROOT" remote get-url origin)"
  run git -C "$ROOT" push -u origin main
else
  run gh repo create "$GH_REPO_NAME" --private --source "$ROOT" --remote origin --push
fi
log "repo: $(gh_repo)"
