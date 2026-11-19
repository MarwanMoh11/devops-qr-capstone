#!/usr/bin/env bash
# make verify-clean: list anything billable this project could have left behind and
# exit 1 if anything is found. Each service is asked through its own API, filtered by
# project/cluster tag, VPC or name prefix, so unrelated resources are not reported.
# Fails closed: an AWS error stops the script (non-zero), it never reports "clean".
. "$(dirname "$0")/lib.sh"
require_aws

found=0
R=(--region "$AWS_REGION" --output json)
cluster_tag="kubernetes.io/cluster/$CLUSTER_NAME"

# report <kind> <ids...>
report() {
  local kind="$1"
  shift
  if [ "$#" -gt 0 ] && [ -n "$*" ]; then
    printf 'FOUND  %-22s %s\n' "$kind" "$*"
    found=1
  else
    printf 'clean  %s\n' "$kind"
  fi
}
q() { local out; out="$("$@")" || die "AWS call failed: $*"; printf '%s' "$out"; }

# Each lookup is a plain assignment, so an AWS error stops the script (set -e) instead
# of looking like an empty result.
# shellcheck disable=SC2086 # word-splitting the id lists is intended
{
x="$(q aws eks list-clusters "${R[@]}" | jq -r --arg c "$CLUSTER_NAME" '.clusters[] | select(. == $c)')"
report "EKS cluster" $x

x="$(q aws ec2 describe-instances "${R[@]}" \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  | jq -r --arg c "$CLUSTER_NAME" --arg t "$cluster_tag" --arg p "$PROJECT" \
    '.Reservations[].Instances[] | select(any(.Tags[]?; (.Key == "eks:cluster-name" and .Value == $c) or .Key == $t or (.Key == "Project" and .Value == $p))) | .InstanceId')"
report "EC2 instances" $x

lbs="$(q aws elbv2 describe-load-balancers "${R[@]}" | jq -r '.LoadBalancers[].LoadBalancerArn')"
lb_hits=""
set -- $lbs
while [ "$#" -gt 0 ]; do
  chunk=""; n=0
  while [ "$#" -gt 0 ] && [ "$n" -lt 20 ]; do chunk="$chunk $1"; shift; n=$((n + 1)); done
  x="$(q aws elbv2 describe-tags "${R[@]}" --resource-arns $chunk \
    | jq -r --arg t "$cluster_tag" --arg p "$PROJECT" '.TagDescriptions[] | select(any(.Tags[]; .Key == $t or (.Key == "Project" and .Value == $p))) | .ResourceArn')"
  lb_hits="$lb_hits $x"
done
report "ELBv2 load balancers" $lb_hits

clbs="$(q aws elb describe-load-balancers "${R[@]}" | jq -r '.LoadBalancerDescriptions[].LoadBalancerName')"
clb_hits=""
set -- $clbs
while [ "$#" -gt 0 ]; do
  chunk=""; n=0
  while [ "$#" -gt 0 ] && [ "$n" -lt 20 ]; do chunk="$chunk $1"; shift; n=$((n + 1)); done
  x="$(q aws elb describe-tags "${R[@]}" --load-balancer-names $chunk \
    | jq -r --arg t "$cluster_tag" '.TagDescriptions[] | select(any(.Tags[]; .Key == $t)) | .LoadBalancerName')"
  clb_hits="$clb_hits $x"
done
report "Classic load balancers" $clb_hits

vols=""
for f in "tag-key,Values=$cluster_tag" "tag:eks:cluster-name,Values=$CLUSTER_NAME" "tag:Project,Values=$PROJECT"; do
  x="$(q aws ec2 describe-volumes "${R[@]}" --filters "Name=$f" | jq -r '.Volumes[].VolumeId')"
  vols="$vols $x"
done
vols="$(printf '%s\n' $vols | sort -u)"
report "EBS volumes" $vols

x="$(q aws ec2 describe-addresses "${R[@]}" \
  | jq -r --arg t "$cluster_tag" --arg p "$PROJECT" '.Addresses[] | select(any(.Tags[]?; .Key == $t or (.Key == "Project" and .Value == $p))) | .AllocationId')"
report "Elastic IPs" $x

x="$(q aws ec2 describe-nat-gateways "${R[@]}" --filter "Name=tag:Project,Values=$PROJECT" \
  | jq -r '.NatGateways[] | select(.State != "deleted") | .NatGatewayId')"
report "NAT gateways" $x

vpcs="$(q aws ec2 describe-vpcs "${R[@]}" --filters "Name=tag:Project,Values=$PROJECT" | jq -r '.Vpcs[].VpcId')"
report "VPCs" $vpcs
enis=""
for v in $vpcs; do
  x="$(q aws ec2 describe-network-interfaces "${R[@]}" --filters "Name=vpc-id,Values=$v" | jq -r '.NetworkInterfaces[].NetworkInterfaceId')"
  enis="$enis $x"
done
report "ENIs" $enis

x="$(q aws ecr describe-repositories "${R[@]}" \
  | jq -r --arg p "$PROJECT/" '.repositories[] | select(.repositoryName | startswith($p)) | .repositoryName')"
report "ECR repositories" $x

x="$(q aws s3api list-buckets --output json \
  | jq -r --arg p "$PROJECT-" '.Buckets[] | select(.Name | startswith($p)) | .Name')"
report "S3 buckets" $x

lgs=""
# /aws/application-signals is account- and region-wide (the CloudWatch add-on's
# Application Signals pipeline); on this project's account it is ours to remove.
for prefix in "/aws/containerinsights/$CLUSTER_NAME" "/aws/eks/$CLUSTER_NAME" "/aws/application-signals"; do
  x="$(q aws logs describe-log-groups "${R[@]}" --log-group-name-prefix "$prefix" | jq -r '.logGroups[].logGroupName')"
  lgs="$lgs $x"
done
report "CloudWatch log groups" $lgs

# Roles named devops-qr-*, plus module-named roles (cluster, node group) tagged Project.
roles="$(q aws iam list-roles --output json | jq -r '.Roles[].RoleName')"
role_hits=""
for r in $roles; do
  case "$r" in
    "$PROJECT"-*) role_hits="$role_hits $r" ;;
    *eks* | *node-group* | default-*)
      tags="$(q aws iam list-role-tags --role-name "$r" --output json)"
      if jq -e --arg p "$PROJECT" '.Tags[]? | select(.Key == "Project" and .Value == $p)' <<<"$tags" >/dev/null; then
        role_hits="$role_hits $r"
      fi ;;
  esac
done
report "IAM roles" $role_hits

providers="$(q aws iam list-open-id-connect-providers --output json \
  | jq -r '.OpenIDConnectProviderList[].Arn | select(endswith("/token.actions.githubusercontent.com"))')"
oidc_hits=""
for arn in $providers; do
  tags="$(q aws iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" --output json)"
  if jq -e --arg p "$PROJECT" '.Tags[]? | select(.Key == "Project" and .Value == $p)' <<<"$tags" >/dev/null; then
    oidc_hits="$oidc_hits $arn"
  fi
done
report "GitHub OIDC provider" $oidc_hits
}

if [ "$found" -ne 0 ]; then
  die "billable resources remain (FOUND lines above). Re-run: make nuke"
fi
log "verify-clean: nothing from $PROJECT left in $AWS_REGION (plus global IAM/S3)"
