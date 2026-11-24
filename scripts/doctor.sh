#!/usr/bin/env bash
# make doctor: tools present and at the pinned versions, Docker running, logins.
# Missing tools or Docker down -> exit 1. Version drift and missing logins -> warnings
# (the cloud scripts re-check logins and stop there).
. "$(dirname "$0")/lib.sh"

fail=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
drift() { printf '  warn  %s\n' "$*"; }

# check <tool> <pinned-version-or-empty> <command printing the version>
check() {
  local tool="$1" want="$2" got
  shift 2
  if ! command -v "$tool" >/dev/null 2>&1; then
    bad "$tool not installed (run: make tools)"
    return
  fi
  got="$("$@" 2>&1 | head -1)" || true
  if [ -n "$want" ] && ! printf '%s' "$got" | grep -q -F "${want#v}"; then
    drift "$tool: pinned $want, found: $got"
  else
    ok "$tool: $got"
  fi
}

echo "Tools"
check terraform "$TERRAFORM_VERSION" terraform version
tf_minor="$(terraform version -json 2>/dev/null | jq -r '.terraform_version' | cut -d. -f1-2 || true)"
case "$tf_minor" in
  1.[0-9]) bad "terraform $tf_minor is too old (need >= 1.10; Homebrew core is frozen at 1.5.7, use hashicorp/tap/terraform)" ;;
esac
check aws "" aws --version
check kubectl "" kubectl version --client
check helm "$HELM_VERSION" helm version --short
check kind "$KIND_VERSION" kind version
check kustomize "$KUSTOMIZE_VERSION" kustomize version
check kubeconform "$KUBECONFORM_VERSION" kubeconform -v
check hadolint "$HADOLINT_VERSION" hadolint --version
check actionlint "$ACTIONLINT_VERSION" actionlint --version
check shellcheck "$SHELLCHECK_VERSION" sh -c 'shellcheck --version | sed -n 2p'
check jq "" jq --version
check gh "" gh --version
check curl "" curl --version
check openssl "" openssl version
check docker "" docker --version

# kind + kube-prometheus-stack need about 4 CPUs and 6-8 GB for the Docker VM.
COLIMA_START="colima start --cpu 4 --memory 8"
echo "Docker"
if docker info >/dev/null 2>&1; then
  mem="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  if [ "$mem" -lt 6000000000 ] 2>/dev/null; then
    drift "Docker has $((mem / 1024 / 1024)) MiB RAM; give it >= 6 GB for kube-prometheus-stack on kind (Colima: colima stop && $COLIMA_START; Docker Desktop: Settings > Resources)"
  else
    ok "Docker is running ($((mem / 1024 / 1024)) MiB RAM)"
  fi
elif command -v colima >/dev/null 2>&1; then
  bad "Docker is not running. Start it with: $COLIMA_START   (or start Docker Desktop if you use that instead)"
else
  bad "Docker is not running. Start Docker Desktop, or install Colima (make tools) and run: $COLIMA_START"
fi

echo "Logins"
if command -v aws >/dev/null 2>&1 && ident="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
  ok "AWS: $ident"
else
  drift "AWS not logged in (needed for cloud targets): aws login   or   aws sso login"
fi
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  ok "GitHub: $(gh api user -q .login 2>/dev/null || echo logged in)"
else
  drift "GitHub not logged in (needed for gh-* and cloud targets): gh auth login"
fi

[ "$fail" -eq 0 ] || die "doctor found problems (see FAIL lines)"
log "doctor: all required checks passed"
