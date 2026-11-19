#!/usr/bin/env bash
# End-to-end check through the web front door:
#   GET /api/healthz -> POST /api/qr -> GET image_url (must be a PNG).
#   scripts/smoke-test.sh <base-url>     e.g. http://localhost:3000
# Waits up to SMOKE_TIMEOUT seconds (default 300) for the URL to answer; a new NLB
# hostname takes 1-3 minutes to resolve (gotcha 20).
. "$(dirname "$0")/lib.sh"
need curl jq

base="${1:-}"
[ -n "$base" ] || die "usage: $0 <base-url>"
base="${base%/}"
limit="${SMOKE_TIMEOUT:-300}"

healthy() { curl -fsS -m 5 "$base/api/healthz"; }
wait_for "$limit" 5 "$base/api/healthz" healthy || die "$base/api/healthz did not answer within ${limit}s"
log "healthz ok"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/devops-qr-smoke.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

code="$(curl -sS -m 20 -o "$tmp/create.json" -w '%{http_code}' -X POST "$base/api/qr" \
  -H 'content-type: application/json' -d '{"url":"https://example.com"}')"
[ "$code" = 201 ] || die "POST /api/qr returned $code: $(head -c 300 "$tmp/create.json")"
image_url="$(jq -r '.image_url // empty' "$tmp/create.json")"
printf '%s' "$image_url" | grep -Eq '^/api/qr/[0-9a-f]{64}$' || die "unexpected image_url '$image_url'"
log "POST /api/qr -> 201, image_url $image_url"

meta="$(curl -sS -m 20 -o "$tmp/qr.png" -w '%{http_code} %{content_type}' "$base$image_url")"
case "$meta" in
  "200 image/png"*) ;;
  *) die "GET $image_url returned '$meta'" ;;
esac
magic="$(head -c 4 "$tmp/qr.png" | od -An -tx1 | tr -d ' \n')"
[ "$magic" = 89504e47 ] || die "GET $image_url did not return PNG bytes"
log "GET $image_url -> 200 image/png ($(wc -c <"$tmp/qr.png" | tr -d ' ') bytes)"
log "smoke test passed: $base"
