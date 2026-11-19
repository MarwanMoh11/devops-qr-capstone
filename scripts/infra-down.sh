#!/usr/bin/env bash
# make infra-down: remove the main stack (cluster, nodes, NLB, ECR, app bucket, logs)
# and stop CI from deploying. Keeps the bootstrap stack (state bucket, CI roles).
# Order matters (§9, gotcha 1): things outside Terraform state go first. Re-runnable.
. "$(dirname "$0")/lib.sh"
require_aws
need terraform kubectl helm jq

log "step 1/5: GitHub variables for the main stack"
"$ROOT/scripts/gh-teardown.sh" main

log "step 2/5: Kubernetes objects that own AWS resources"
# Assign first: a die inside $(...) used directly in [ ] would not stop the script.
cluster="$(cluster_exists)"
if [ "$cluster" = true ]; then
  if kubeconfig_eks && kubectl --context "$EKS_CONTEXT" get ns >/dev/null 2>&1; then
    k() { run kubectl --context "$EKS_CONTEXT" "$@"; }
    # Any LoadBalancer Service, in any namespace, owns an NLB/CLB.
    kubectl --context "$EKS_CONTEXT" get svc -A -o json \
      | jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r ns name; do k -n "$ns" delete svc "$name" --wait=true --timeout=5m || true; done
    k delete namespace "$APP_NS" --ignore-not-found --wait=true --timeout=5m || warn "namespace $APP_NS not fully deleted"
    run helm uninstall "$KPS_RELEASE" --kube-context "$EKS_CONTEXT" -n "$MON_NS" --ignore-not-found --wait --timeout 5m \
      || warn "helm uninstall $KPS_RELEASE failed"
    k delete namespace "$MON_NS" --ignore-not-found --wait=true --timeout=5m || warn "namespace $MON_NS not fully deleted"
  else
    warn "cannot reach the cluster API; skipping Kubernetes cleanup (lb-cleanup will force-delete)"
  fi
else
  log "cluster $CLUSTER_NAME not found; skipping"
fi

log "step 3/5: leftover load balancers, k8s-* security groups, detached ENIs"
"$ROOT/scripts/lb-cleanup.sh"

log "step 4/5: terraform destroy infra/main"
bucket="$(state_bucket)"
# Only a definite 404 skips the destroy; any other head-bucket error aborts here.
bucket_found="$(bucket_exists "$bucket")"
if [ "$bucket_found" = true ]; then
  tf_main_init
  tf_main destroy -auto-approve
else
  log "state bucket $bucket not found (404); main stack has no state to destroy"
fi

log "step 5/5: sweep log groups created outside Terraform"
# /aws/application-signals/ is account- and region-wide, not per cluster: the
# CloudWatch add-on's Application Signals pipeline writes /aws/application-signals/data.
for prefix in "/aws/containerinsights/$CLUSTER_NAME/" "/aws/eks/$CLUSTER_NAME/" "/aws/application-signals/"; do
  groups="$(aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix "$prefix" \
    --output json | jq -r '.logGroups[].logGroupName')"
  for g in $groups; do
    run aws logs delete-log-group --region "$AWS_REGION" --log-group-name "$g"
  done
done
log "infra-down done (bootstrap stack kept; make nuke removes it too)"
