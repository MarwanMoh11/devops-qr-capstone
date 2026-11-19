#!/usr/bin/env bash
# make lint: every static check CI runs, same commands.
#   scripts/lint.sh [all|shell|actions|docker|terraform|k8s|monitoring]
. "$(dirname "$0")/lib.sh"

KCF_VERSION="${KUBERNETES_VERSION}.0"
# Placeholder values used only to render the eks overlay for validation.
FAKE_REGISTRY="123456789012.dkr.ecr.$AWS_REGION.amazonaws.com"
FAKE_SHA="0000000000000000000000000000000000000000"

lint_shell() {
  need shellcheck
  run shellcheck "$ROOT"/scripts/*.sh
}

lint_actions() {
  need actionlint
  (cd "$ROOT" && run actionlint)
}

lint_docker() {
  need hadolint
  local cfg=()
  [ -f "$ROOT/.hadolint.yaml" ] && cfg=(--config "$ROOT/.hadolint.yaml")
  run hadolint "${cfg[@]+"${cfg[@]}"}" "$ROOT/api/Dockerfile" "$ROOT/front-end-nextjs/Dockerfile"
}

# CI installs tflint with terraform-linters/setup-tflint; the laptop runs the pinned
# image. --init and --recursive run in ONE container so the downloaded aws ruleset is kept.
run_tflint() {
  if command -v tflint >/dev/null 2>&1; then
    (cd "$ROOT/infra" && run tflint --init --config "$ROOT/infra/.tflint.hcl" \
      && run tflint --recursive --config "$ROOT/infra/.tflint.hcl")
  else
    need docker
    run docker run --rm -v "$ROOT/infra:/data" -w /data -e GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
      --entrypoint sh "$TFLINT_IMAGE" \
      -c 'tflint --init --config /data/.tflint.hcl && tflint --recursive --config /data/.tflint.hcl'
  fi
}

lint_terraform() {
  need terraform
  local s
  run terraform fmt -check -recursive "$ROOT/infra"
  for s in bootstrap main; do
    run terraform -chdir="$ROOT/infra/$s" init -backend=false -input=false >/dev/null
    run terraform -chdir="$ROOT/infra/$s" validate
  done
  run_tflint
}

kubeconform_k8s() {
  run kubeconform -strict -summary -kubernetes-version "$KCF_VERSION" -ignore-missing-schemas
}

lint_k8s() {
  need kustomize kubeconform
  local d overlay
  for d in base overlays/local; do
    log "kustomize build k8s/$d | kubeconform"
    kustomize build "$ROOT/k8s/$d" | kubeconform_k8s
  done
  overlay="$(temp_overlay eks)"
  set_overlay_values "$overlay" \
    "$FAKE_REGISTRY/$ECR_REPO_API:$FAKE_SHA" "$FAKE_REGISTRY/$ECR_REPO_WEB:$FAKE_SHA" \
    "S3_BUCKET=$PROJECT-qrcodes-123456789012" "AWS_REGION=$AWS_REGION"
  log "kustomize build k8s/overlays/eks (temp copy, placeholders set) | kubeconform"
  kustomize build "$overlay" | kubeconform_k8s
  rm -rf "${overlay%/k8s/overlays/eks}"
}

lint_monitoring() {
  need helm kubeconform kustomize jq
  local extra
  for extra in "" kps-values-kind.yaml; do
    log "helm template $KPS_CHART $KPS_CHART_VERSION ${extra:+(+ $extra)} | kubeconform"
    if [ -n "$extra" ]; then
      helm template "$KPS_RELEASE" "$KPS_CHART" --version "$KPS_CHART_VERSION" -n "$MON_NS" \
        -f "$ROOT/monitoring/kps-values.yaml" -f "$ROOT/monitoring/$extra" \
        | kubeconform -summary -kubernetes-version "$KCF_VERSION" -ignore-missing-schemas
    else
      helm template "$KPS_RELEASE" "$KPS_CHART" --version "$KPS_CHART_VERSION" -n "$MON_NS" \
        -f "$ROOT/monitoring/kps-values.yaml" \
        | kubeconform -summary -kubernetes-version "$KCF_VERSION" -ignore-missing-schemas
    fi
  done
  log "kustomize build monitoring | kubeconform"
  kustomize build "$ROOT/monitoring" | kubeconform_k8s
  run jq empty "$ROOT/monitoring/dashboards/qr-services.json"
}

part="${1:-all}"
case "$part" in
  all)
    lint_shell
    lint_actions
    lint_docker
    lint_terraform
    lint_k8s
    lint_monitoring
    ;;
  shell | actions | docker | terraform | k8s | monitoring) "lint_$part" ;;
  *) die "usage: $0 [all|shell|actions|docker|terraform|k8s|monitoring]" ;;
esac
log "lint ($part): passed"
