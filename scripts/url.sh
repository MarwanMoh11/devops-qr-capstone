#!/usr/bin/env bash
# Print the public URL (http://<nlb-dns>) of qr-web on EKS. Waits up to URL_TIMEOUT
# seconds (default 300) for the LoadBalancer hostname to be assigned.
. "$(dirname "$0")/lib.sh"
need kubectl

hostname_of() {
  kubectl --context "$EKS_CONTEXT" -n "$APP_NS" get svc qr-web \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}
has_hostname() { [ -n "$(hostname_of)" ]; }

wait_for "${URL_TIMEOUT:-300}" 10 "the qr-web LoadBalancer hostname" has_hostname \
  || die "svc/qr-web in $APP_NS has no LoadBalancer hostname yet (kubectl --context $EKS_CONTEXT -n $APP_NS describe svc qr-web)"
echo "http://$(hostname_of)"
