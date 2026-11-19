# shellcheck shell=bash
# Shared helpers. Every script starts with:
#   . "$(dirname "$0")/lib.sh"
# Written for macOS's stock bash 3.2 and BSD tools as well as Linux CI runners.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

set -a
# shellcheck source=../project.env
. "$ROOT/project.env"
# shellcheck source=../tool-versions.env
. "$ROOT/tool-versions.env"
set +a

TF_BOOT="$ROOT/infra/bootstrap"
TF_MAIN="$ROOT/infra/main"
KIND_CONTEXT="kind-$KIND_CLUSTER"
EKS_CONTEXT="$CLUSTER_NAME" # alias given to `aws eks update-kubeconfig`

# ---------------------------------------------------------------- output
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Print a command, then run it. The RUNBOOK's command lists come from these lines.
run()  { printf '+ %s\n' "$*" >&2; "$@"; }

need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "missing tool: $t (run: make tools)"
  done
}

# wait_for <seconds> <interval> <description> <command...>: poll until the command succeeds.
wait_for() {
  local limit="$1" every="$2" what="$3" deadline
  shift 3
  deadline=$(( $(date +%s) + limit ))
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    log "waiting for $what ..."
    sleep "$every"
  done
}

# ---------------------------------------------------------------- kube contexts
# Every kubectl/helm call names its context, so a teardown can never hit kind and
# a kind deploy can never hit EKS.
kube_context() {
  case "$1" in
    eks) echo "$EKS_CONTEXT" ;;
    kind | local) echo "$KIND_CONTEXT" ;;
    *) die "unknown cluster '$1' (expected kind or eks)" ;;
  esac
}

# ---------------------------------------------------------------- AWS
require_aws() {
  need aws jq
  aws sts get-caller-identity --output json >/dev/null 2>&1 \
    || die "AWS CLI is not logged in. Run: aws configure   (or: aws sso login)"
}

aws_account_id() { aws sts get-caller-identity --query Account --output text; }

# Refuse AWS Academy / Learner Lab style accounts: they block IAM roles and OIDC providers.
check_account_type() {
  local arn
  arn="$(aws sts get-caller-identity --query Arn --output text)"
  case "$arn" in
    *:root)
      die "you are logged in as the account root user ($arn). Use an IAM user or an SSO/role identity; bootstrap rejects root as the cluster admin principal." ;;
    *voclabs* | *vocstartsoft* | *LabRole*)
      die "this looks like an AWS Academy/Learner Lab account ($arn); it cannot create IAM roles or OIDC providers. Use a standard account." ;;
  esac
  aws iam list-open-id-connect-providers --output json >/dev/null 2>&1 \
    || die "this identity cannot read IAM ($arn). The design needs an account where you can manage IAM roles."
}

# Fails closed: anything but STANDARD_SUPPORT (including an API error) stops the run.
check_eks_version() {
  local out status
  out="$(aws eks describe-cluster-versions --region "$AWS_REGION" \
    --cluster-versions "$KUBERNETES_VERSION" --output json)" \
    || die "aws eks describe-cluster-versions failed; cannot confirm $KUBERNETES_VERSION is in standard support"
  status="$(jq -r '.clusterVersions[0].versionStatus // empty' <<<"$out")"
  [ "$status" = "STANDARD_SUPPORT" ] \
    || die "EKS $KUBERNETES_VERSION is '${status:-not listed}', not STANDARD_SUPPORT (extended support costs 6x). Change KUBERNETES_VERSION in project.env and infra/main."
  log "EKS $KUBERNETES_VERSION is in standard support"
}

preflight_cloud() {
  need terraform kubectl helm kustomize jq curl gh
  require_aws
  check_account_type
  require_gh
}

# Prints true/false; any error other than "not found" aborts.
cluster_exists() {
  local err
  if err="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" --output json 2>&1 >/dev/null)"; then
    echo true
  elif printf '%s' "$err" | grep -q ResourceNotFoundException; then
    echo false
  else
    die "aws eks describe-cluster failed: $err"
  fi
}

# Prints true/false for an S3 bucket. Only a definite 404/NoSuchBucket counts as
# absent; a throttle, 403 or network error aborts, because "absent" makes teardown
# skip the main destroy and delete the state of a stack that is still billing.
# Call it as an assignment (b="$(bucket_exists x)"), never inside [ ], so the
# die in the subshell stops the script under set -e.
bucket_exists() {
  local err
  if err="$(aws s3api head-bucket --bucket "$1" 2>&1 >/dev/null)"; then
    echo true
  elif printf '%s' "$err" | grep -q -E '\(404\)|NoSuchBucket|Not Found'; then
    echo false
  else
    die "aws s3api head-bucket --bucket $1 failed and it is not a 404, so the bucket may still exist: $err"
  fi
}

kubeconfig_eks() {
  run aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$EKS_CONTEXT"
}

ecr_registry() { echo "${ECR_REGISTRY:-$(aws_account_id).dkr.ecr.$AWS_REGION.amazonaws.com}"; }
app_bucket()   { echo "${S3_BUCKET:-$PROJECT-qrcodes-$(aws_account_id)}"; }

# ---------------------------------------------------------------- GitHub
require_gh() {
  need gh
  gh auth status >/dev/null 2>&1 || die "GitHub CLI is not logged in. Run: gh auth login"
}

# owner/name of the repo behind the `origin` remote (empty if none).
gh_repo() { gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true; }

# ---------------------------------------------------------------- Terraform
tf_boot_out() { terraform -chdir="$TF_BOOT" output -raw "$1" 2>/dev/null || true; }

boot_state_exists() {
  [ -s "$TF_BOOT/terraform.tfstate" ] && terraform -chdir="$TF_BOOT" state list 2>/dev/null | grep -q .
}

# true when the bootstrap state already manages the GitHub OIDC provider
boot_owns_oidc() {
  terraform -chdir="$TF_BOOT" state list 2>/dev/null \
    | grep -v -E '(^|\.)data\.' | grep -q -E '(^|\.)aws_iam_openid_connect_provider\.'
}

# Value for create_github_oidc_provider. Only false when the provider exists AND
# this project's state does not own it; flipping it on a re-run would destroy it.
oidc_toggle() {
  local list
  if boot_owns_oidc; then echo true; return; fi
  list="$(aws iam list-open-id-connect-providers --output json)" || die "cannot list IAM OIDC providers"
  if jq -e '.OpenIDConnectProviderList[].Arn | select(endswith("/token.actions.githubusercontent.com"))' <<<"$list" >/dev/null; then
    echo false
  else
    echo true
  fi
}

state_bucket() {
  local b
  b="$(tf_boot_out tf_state_bucket)"
  [ -n "$b" ] || b="$PROJECT-tfstate-$(aws_account_id)"
  echo "$b"
}

# IAM ARN of the caller (role ARN, not the STS session ARN). Fallback only.
caller_principal_arn() {
  local arn role
  arn="$(aws sts get-caller-identity --query Arn --output text)"
  case "$arn" in
    arn:aws:sts::*:assumed-role/*)
      role="${arn#*:assumed-role/}"; role="${role%%/*}"
      aws iam get-role --role-name "$role" --query Role.Arn --output text ;;
    *) echo "$arn" ;;
  esac
}

admin_principal_arn() {
  local a
  a="$(tf_boot_out admin_principal_arn)"
  [ -n "$a" ] || a="$(caller_principal_arn)"
  echo "$a"
}

tf_main_init() {
  run terraform -chdir="$TF_MAIN" init -input=false -reconfigure \
    -backend-config="bucket=$(state_bucket)" \
    -backend-config="key=$TF_STATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="use_lockfile=true"
}

# terraform -chdir=infra/main <plan|apply|destroy> with every required -var.
tf_main() {
  local cmd="$1"
  shift
  run terraform -chdir="$TF_MAIN" "$cmd" -input=false \
    -var "region=$AWS_REGION" \
    -var "kubernetes_version=$KUBERNETES_VERSION" \
    -var "admin_principal_arn=$(admin_principal_arn)" \
    "$@"
}

# Refuses (dies) unless the main stack is provably gone: the cluster is absent and
# main's state is empty or its bucket is a definite 404. make nuke calls this before
# deleting the bootstrap stack, whose state bucket holds main's state.
require_main_stack_gone() {
  local c bucket b out
  c="$(cluster_exists)"
  [ "$c" = false ] \
    || die "EKS cluster $CLUSTER_NAME still exists; refusing to delete the bootstrap stack (it holds the main stack's state). Run: make infra-down, then make nuke"
  bucket="$(state_bucket)"
  b="$(bucket_exists "$bucket")"
  if [ "$b" = false ]; then
    log "state bucket $bucket not found (404); main stack has no state"
    return 0
  fi
  tf_main_init >&2 || die "cannot initialise infra/main against s3://$bucket; refusing to delete the bootstrap stack. Fix the error above, then: make infra-down && make nuke"
  if ! out="$(terraform -chdir="$TF_MAIN" state list 2>&1)"; then
    printf '%s' "$out" | grep -q 'No state file was found' \
      || die "cannot read the main stack's state: $out
Refusing to delete the bootstrap stack. Fix the error, then: make infra-down && make nuke"
    out=""
  fi
  [ -z "$out" ] \
    || die "main stack state still lists $(printf '%s\n' "$out" | grep -c .) resource(s); refusing to delete the bootstrap stack. Run: make infra-down, then make nuke"
  log "main stack state is empty"
}

# terraform -chdir=infra/bootstrap <apply|destroy> with every required -var.
tf_boot() {
  local cmd="$1" repo
  shift
  repo="${GITHUB_REPO:-$(gh_repo)}"
  [ -n "$repo" ] || die "no GitHub repo behind 'origin'. Run: make gh-repo"
  run terraform -chdir="$TF_BOOT" "$cmd" -input=false \
    -var "region=$AWS_REGION" \
    -var "github_repo=$repo" \
    -var "create_github_oidc_provider=$(oidc_toggle)" \
    "$@"
}

# ---------------------------------------------------------------- Kustomize (D8)
# The ONLY place deploy-time values enter the manifests. It edits the overlay in
# a temp copy of k8s/, never the committed files.
#   set_overlay_values <overlay-dir> <api-image-ref> <web-image-ref> [KEY=VALUE ...]
# KEY=VALUE pairs are merged into the qr-api-config ConfigMap. The eks overlay has no
# configMapGenerator on purpose, so the first edit is the single command C1 tested:
#   kustomize edit add configmap qr-api-config --behavior=merge --from-literal=K=V ...
# If an overlay already carries a qr-api-config generator (the local one does), each key
# is updated with `edit set configmap` (existing key) or `edit add` (new key), because
# `add` refuses a key that exists and `set` refuses a key that does not.
set_overlay_values() {
  local dir="$1" api_ref="$2" web_ref="$3" kv
  shift 3
  (
    cd "$dir"
    run kustomize edit set image "qr-api=$api_ref" "qr-web=$web_ref"
    [ "$#" -gt 0 ] || exit 0
    if ! grep -q 'name: qr-api-config' kustomization.yaml; then
      local lits=()
      for kv in "$@"; do lits+=("--from-literal=$kv"); done
      run kustomize edit add configmap qr-api-config --behavior=merge "${lits[@]}"
      exit 0
    fi
    for kv in "$@"; do
      if kustomize edit set configmap qr-api-config --from-literal="$kv" >/dev/null 2>&1; then
        printf '+ kustomize edit set configmap qr-api-config --from-literal=%s\n' "$kv" >&2
      else
        run kustomize edit add configmap qr-api-config --behavior=merge --from-literal="$kv"
      fi
    done
  )
}

# Copy k8s/ to a temp dir and print the path of the copied overlay.
temp_overlay() {
  local env="$1" tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/devops-qr-k8s.XXXXXX")"
  cp -R "$ROOT/k8s" "$tmp/"
  echo "$tmp/k8s/overlays/$env"
}
