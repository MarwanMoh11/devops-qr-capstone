#!/usr/bin/env bash
# CI only (ubuntu, linux/amd64): install pinned tools from their GitHub releases into
# $RUNNER_TEMP/bin, checking each archive against the release's checksum file.
#   scripts/ci-install-tools.sh kustomize kubeconform actionlint shellcheck hadolint
. "$(dirname "$0")/lib.sh"
need curl

bin="${RUNNER_TEMP:-/tmp}/bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$bin"

# fetch <url> <checksums-url>: download into $work and verify the sha256.
fetch() {
  local url="$1" sums="$2" file
  file="$(basename "$url")"
  curl -fsSL -o "$work/$file" "$url"
  curl -fsSL -o "$work/sums" "$sums"
  (cd "$work" && grep " \*\{0,1\}$file\$" sums | sha256sum -c -) || die "checksum mismatch for $file"
}

for tool in "$@"; do
  case "$tool" in
    kustomize)
      base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv$KUSTOMIZE_VERSION"
      fetch "$base/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" "$base/checksums.txt"
      tar -xzf "$work/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" -C "$bin" kustomize ;;
    kubeconform)
      base="https://github.com/yannh/kubeconform/releases/download/v$KUBECONFORM_VERSION"
      fetch "$base/kubeconform-linux-amd64.tar.gz" "$base/CHECKSUMS"
      tar -xzf "$work/kubeconform-linux-amd64.tar.gz" -C "$bin" kubeconform ;;
    actionlint)
      base="https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION"
      fetch "$base/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" "$base/actionlint_${ACTIONLINT_VERSION}_checksums.txt"
      tar -xzf "$work/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" -C "$bin" actionlint ;;
    shellcheck)
      # No checksum file is published for shellcheck; pinned by version over HTTPS.
      curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.gz" \
        | tar -xz -C "$work"
      install -m 0755 "$work/shellcheck-v$SHELLCHECK_VERSION/shellcheck" "$bin/shellcheck" ;;
    hadolint)
      base="https://github.com/hadolint/hadolint/releases/download/v$HADOLINT_VERSION"
      fetch "$base/hadolint-linux-x86_64" "$base/checksums.sha256"
      install -m 0755 "$work/hadolint-linux-x86_64" "$bin/hadolint" ;;
    *) die "unknown tool $tool" ;;
  esac
  log "installed $tool"
done

if [ -n "${GITHUB_PATH:-}" ]; then echo "$bin" >>"$GITHUB_PATH"; fi
