#!/usr/bin/env bash
# Render an overlay from a temp copy of k8s/, apply it, wait for the rollouts (D8).
#   scripts/deploy.sh local dev          (kind; images qr-api:dev / qr-web:dev)
#   scripts/deploy.sh eks <40-char-sha>  (CI, or `make deploy` from the laptop)
# eks reads ECR_REGISTRY and S3_BUCKET from the environment (CI sets them from repo
# variables); on the laptop they default to the contract names for this account.
. "$(dirname "$0")/lib.sh"
need kubectl kustomize

env="${1:-}"
tag="${2:-}"
[ -n "$env" ] && [ -n "$tag" ] || die "usage: $0 <local|eks> <tag>"
ctx="$(kube_context "$env")"

overlay="$(temp_overlay "$env")"
tmp="${overlay%/k8s/overlays/"$env"}"
trap 'rm -rf "$tmp"' EXIT

case "$env" in
  local)
    set_overlay_values "$overlay" "qr-api:$tag" "qr-web:$tag"
    ;;
  eks)
    printf '%s' "$tag" | grep -Eq '^[0-9a-f]{40}$' || die "eks tag must be a full 40-char git SHA, got '$tag'"
    registry="$(ecr_registry)"
    set_overlay_values "$overlay" \
      "$registry/$ECR_REPO_API:$tag" "$registry/$ECR_REPO_WEB:$tag" \
      "S3_BUCKET=$(app_bucket)" "AWS_REGION=$AWS_REGION"
    ;;
  *) die "unknown env '$env' (expected local or eks)" ;;
esac

if [ "$env" = eks ]; then
  # The CI deploy role cannot create namespaces (edit access scoped to qr-app only).
  # It may not be allowed to read Namespace objects either, so only a clear NotFound stops here.
  if ns_err="$(kubectl --context "$ctx" get namespace "$APP_NS" 2>&1 >/dev/null)"; then
    :
  elif printf '%s' "$ns_err" | grep -q NotFound; then
    die "namespace $APP_NS does not exist on EKS. An admin must create it first: make platform-up (or make infra-up)"
  fi
fi

log "kustomize build k8s/overlays/$env (temp copy)"
kustomize build "$overlay" >"$tmp/rendered.yaml"

if [ "$env" = local ]; then
  # Jobs are immutable and MinIO keeps data in an emptyDir, so the bucket-init Job
  # (idempotent) is deleted and re-applied on every deploy to recreate the bucket.
  run kubectl --context "$ctx" -n "$APP_NS" delete job --all --ignore-not-found
fi

run kubectl --context "$ctx" apply -f "$tmp/rendered.yaml"

if [ "$env" = local ]; then
  run kubectl --context "$ctx" -n "$APP_NS" wait --for=condition=complete job --all --timeout=360s
fi

for d in qr-api qr-web; do
  run kubectl --context "$ctx" -n "$APP_NS" rollout status "deploy/$d" --timeout=300s
done
log "deployed $env:$tag"
