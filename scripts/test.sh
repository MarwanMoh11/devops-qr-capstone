#!/usr/bin/env bash
# make test: run each app's tests inside its Dockerfile `test` stage (D14).
. "$(dirname "$0")/lib.sh"
need docker

run docker build --target test "$ROOT/api"
run docker build --target test "$ROOT/front-end-nextjs"
log "tests passed (api: ruff + pytest, web: eslint)"
