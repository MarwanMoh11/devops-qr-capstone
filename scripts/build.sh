#!/usr/bin/env bash
# make build: native (laptop architecture) runtime images qr-api:dev and qr-web:dev.
# These are for compose and kind only and are never pushed (gotcha 8).
. "$(dirname "$0")/lib.sh"
need docker

run docker build --target runtime -t "qr-api:$LOCAL_TAG" "$ROOT/api"
run docker build --target runtime -t "qr-web:$LOCAL_TAG" "$ROOT/front-end-nextjs"
