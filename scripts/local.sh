#!/usr/bin/env bash
# Docker Compose flow:  scripts/local.sh <up|smoke|logs|down>
. "$(dirname "$0")/lib.sh"
need docker

compose() { run docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml" "$@"; }

case "${1:-}" in
  up)
    compose up -d --build --wait
    log "app: http://localhost:$LOCAL_HTTP_PORT   (MinIO console: http://localhost:9001)"
    ;;
  smoke) "$ROOT/scripts/smoke-test.sh" "http://localhost:$LOCAL_HTTP_PORT" ;;
  logs) compose logs --no-color --tail=200 ;;
  down) compose down -v --remove-orphans ;;
  *) die "usage: $0 <up|smoke|logs|down>" ;;
esac
