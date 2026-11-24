#!/usr/bin/env bash
# Local Kubernetes flow:  scripts/kind.sh <up|deploy|smoke|monitoring|down>
. "$(dirname "$0")/lib.sh"
need kind kubectl kustomize docker

kind_exists() { kind get clusters 2>/dev/null | grep -x "$KIND_CLUSTER" >/dev/null; }

# Third-party images the local overlay uses, referenced by tag (e.g. amazon/aws-cli).
# Pulling them inside the single kind node is slow and can starve etcd and the
# probes, so pull on the host (cached after `make local-up`) and load them.
# Digest-pinned refs are skipped: the node cannot match an index digest to a
# single-platform import, and the one we use (MinIO, ~60 MB) pulls fast in-node.
third_party_tagged_images() {
  kustomize build "$ROOT/k8s/overlays/local" \
    | awk '$1 == "image:" { print $2 }' \
    | grep -vE "^qr-(api|web):|@sha256:" \
    | sort -u
}

case "${1:-}" in
  up)
    if kind_exists; then
      log "kind cluster $KIND_CLUSTER already exists"
    else
      run kind create cluster --name "$KIND_CLUSTER" --config "$ROOT/k8s/kind/cluster.yaml" --wait 120s
    fi
    run kubectl --context "$KIND_CONTEXT" get nodes
    ;;
  deploy)
    kind_exists || die "no kind cluster. Run: make kind-up"
    "$ROOT/scripts/build.sh"
    run kind load docker-image "qr-api:$LOCAL_TAG" "qr-web:$LOCAL_TAG" --name "$KIND_CLUSTER"
    # Save one platform only: with Docker's containerd image store, a plain
    # `kind load docker-image` of a multi-arch image fails ("content digest not found").
    platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}')"
    archive="$(mktemp "${TMPDIR:-/tmp}/qr-kind-image.XXXXXX")"
    while read -r img; do
      docker image inspect "$img" >/dev/null 2>&1 || run docker pull --platform "$platform" "$img"
      run docker save --platform "$platform" -o "$archive" "$img"
      run kind load image-archive "$archive" --name "$KIND_CLUSTER"
    done < <(third_party_tagged_images)
    rm -f "$archive"
    run kubectl --context "$KIND_CONTEXT" apply -f "$ROOT/k8s/namespace.yaml"
    "$ROOT/scripts/deploy.sh" local "$LOCAL_TAG"
    log "app: http://localhost:$KIND_HTTP_PORT"
    ;;
  smoke) "$ROOT/scripts/smoke-test.sh" "http://localhost:$KIND_HTTP_PORT" ;;
  monitoring) "$ROOT/scripts/monitoring-up.sh" kind ;;
  down)
    if kind_exists; then
      run kind delete cluster --name "$KIND_CLUSTER"
    else
      log "kind cluster $KIND_CLUSTER does not exist"
    fi
    ;;
  *) die "usage: $0 <up|deploy|smoke|monitoring|down>" ;;
esac
