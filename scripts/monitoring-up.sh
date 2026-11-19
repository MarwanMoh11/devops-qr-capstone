#!/usr/bin/env bash
# Install kube-prometheus-stack and the QR dashboard (§7).
#   scripts/monitoring-up.sh <kind|eks>
# Needs cluster-admin (the CI deploy role cannot install CRDs), so it runs from the laptop.
. "$(dirname "$0")/lib.sh"
need kubectl helm openssl

cluster="${1:-}"
[ -n "$cluster" ] || die "usage: $0 <kind|eks>"
ctx="$(kube_context "$cluster")"
kc() { run kubectl --context "$ctx" "$@"; }

if ! kubectl --context "$ctx" get namespace "$MON_NS" >/dev/null 2>&1; then
  kc create namespace "$MON_NS"
fi

if kubectl --context "$ctx" -n "$MON_NS" get secret "$GRAFANA_SECRET" >/dev/null 2>&1; then
  log "secret $MON_NS/$GRAFANA_SECRET exists, keeping it"
else
  log "creating secret $MON_NS/$GRAFANA_SECRET with a random admin password"
  kubectl --context "$ctx" -n "$MON_NS" create secret generic "$GRAFANA_SECRET" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)" >/dev/null
fi

values=(-f "$ROOT/monitoring/kps-values.yaml")
env_values="$ROOT/monitoring/kps-values-$cluster.yaml"
[ -f "$env_values" ] && values+=(-f "$env_values")

run helm upgrade --install "$KPS_RELEASE" "$KPS_CHART" --version "$KPS_CHART_VERSION" \
  --kube-context "$ctx" -n "$MON_NS" "${values[@]}" --wait --timeout 10m

kc apply -k "$ROOT/monitoring"

# helm --wait covers the chart's Deployments, but the operator creates the
# Prometheus StatefulSet afterwards, so wait for it before reporting ready.
for _ in $(seq 1 30); do
  kubectl --context "$ctx" -n "$MON_NS" get statefulset prometheus-kps-prometheus >/dev/null 2>&1 && break
  sleep 5
done
kc -n "$MON_NS" rollout status statefulset/prometheus-kps-prometheus --timeout=5m
log "monitoring ready. Grafana: make grafana$( [ "$cluster" = kind ] && echo ' CLUSTER=kind')"
