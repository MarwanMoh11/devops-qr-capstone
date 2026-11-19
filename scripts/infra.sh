#!/usr/bin/env bash
# infra/main from the laptop (D10: CI never applies).
#   scripts/infra.sh plan   terraform plan (read-only)
#   scripts/infra.sh up     preflight (EKS version in standard support), apply,
#                           kubeconfig, GitHub variables. About 15-20 minutes.
. "$(dirname "$0")/lib.sh"
preflight_cloud
boot_state_exists || die "bootstrap stack not applied (no infra/bootstrap/terraform.tfstate). Run: make bootstrap"

case "${1:-}" in
  plan)
    tf_main_init
    tf_main plan
    ;;
  up)
    check_eks_version
    tf_main_init
    tf_main apply -auto-approve
    kubeconfig_eks
    run kubectl --context "$EKS_CONTEXT" get nodes
    # The CI deploy role is namespace-scoped and cannot create qr-app; the admin does it here.
    run kubectl --context "$EKS_CONTEXT" apply -f "$ROOT/k8s/namespace.yaml"
    "$ROOT/scripts/gh-setup.sh"
    ;;
  *) die "usage: $0 <plan|up>" ;;
esac
