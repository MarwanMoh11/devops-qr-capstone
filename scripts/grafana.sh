#!/usr/bin/env bash
# Print the Grafana login and port-forward it to http://localhost:3001 (never public).
#   scripts/grafana.sh <kind|eks>        Ctrl-C stops the port-forward.
. "$(dirname "$0")/lib.sh"
need kubectl

ctx="$(kube_context "${1:-eks}")"
secret_field() {
  kubectl --context "$ctx" -n "$MON_NS" get secret "$GRAFANA_SECRET" \
    -o jsonpath="{.data.$1}" | base64 --decode
}
user="$(secret_field admin-user)" || die "secret $MON_NS/$GRAFANA_SECRET not found. Run: make monitoring-up (or make kind-monitoring)"
log "Grafana: http://localhost:$GRAFANA_LOCAL_PORT   user: $user   password: $(secret_field admin-password)"
log "Dashboard: Dashboards -> QR services (uid qr-services)"
run kubectl --context "$ctx" -n "$MON_NS" port-forward "svc/$GRAFANA_SVC" "$GRAFANA_LOCAL_PORT:80"
