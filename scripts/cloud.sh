#!/usr/bin/env bash
# Day-to-day EKS helpers:
#   scripts/cloud.sh kubeconfig    write the kubeconfig context "devops-qr-eks"
#   scripts/cloud.sh platform-up   namespace qr-app + monitoring (cluster-admin steps)
#   scripts/cloud.sh deploy        laptop escape hatch: deploy origin/main's SHA
#                                  (images must already be in ECR; CI builds them)
#   scripts/cloud.sh status        nodes, pods, services, URL, recent CI runs
. "$(dirname "$0")/lib.sh"
require_aws
need kubectl

case "${1:-}" in
  kubeconfig) kubeconfig_eks ;;
  platform-up)
    kubeconfig_eks
    run kubectl --context "$EKS_CONTEXT" apply -f "$ROOT/k8s/namespace.yaml"
    "$ROOT/scripts/monitoring-up.sh" eks
    ;;
  deploy)
    run git -C "$ROOT" fetch origin main
    sha="$(git -C "$ROOT" rev-parse origin/main)"
    for repo in "$ECR_REPO_API" "$ECR_REPO_WEB"; do
      run aws ecr describe-images --region "$AWS_REGION" --repository-name "$repo" \
        --image-ids "imageTag=$sha" --output text --query 'imageDetails[0].imageTags[0]' >/dev/null \
        || die "$repo:$sha is not in ECR. Run: make release (CI builds linux/amd64 images)"
    done
    kubeconfig_eks
    "$ROOT/scripts/deploy.sh" eks "$sha"
    ;;
  status)
    k() { run kubectl --context "$EKS_CONTEXT" "$@" || true; }
    k get nodes -o wide
    k -n "$APP_NS" get deploy,pods,svc
    k -n "$MON_NS" get pods
    k -n "$CW_NS" get pods
    URL_TIMEOUT=1 "$ROOT/scripts/url.sh" 2>/dev/null || log "no public URL yet"
    if gh auth status >/dev/null 2>&1 && [ -n "$(gh_repo)" ]; then
      run gh run list --repo "$(gh_repo)" --limit 5 || true
    fi
    ;;
  *) die "usage: $0 <kubeconfig|platform-up|deploy|status>" ;;
esac
