#!/usr/bin/env bash
# Teardown step 3 (§9): make sure no load balancer, k8s-* security group or detached
# ENI is left in the project VPC, because any of them blocks `terraform destroy`.
# Waits up to LB_WAIT seconds (default 300) for the cloud controller to delete the
# NLB after the Service is gone, then force-deletes whatever is left.
. "$(dirname "$0")/lib.sh"
require_aws

vpc="$(terraform -chdir="$TF_MAIN" output -raw vpc_id 2>/dev/null || true)"
if [ -z "$vpc" ]; then
  vpc="$(aws ec2 describe-vpcs --region "$AWS_REGION" --output json \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Stack,Values=main" \
    | jq -r '.Vpcs[0].VpcId // empty')"
fi
if [ -z "$vpc" ]; then
  log "no project VPC found; nothing to clean"
  exit 0
fi
log "VPC $vpc"

lbs_v2() {
  aws elbv2 describe-load-balancers --region "$AWS_REGION" --output json \
    | jq -r --arg v "$vpc" '.LoadBalancers[] | select(.VpcId == $v) | .LoadBalancerArn'
}
lbs_v1() {
  aws elb describe-load-balancers --region "$AWS_REGION" --output json \
    | jq -r --arg v "$vpc" '.LoadBalancerDescriptions[] | select(.VPCId == $v) | .LoadBalancerName'
}
# An AWS error counts as "not gone yet" (fail closed).
no_lbs() {
  local a b
  a="$(lbs_v2)" || return 1
  b="$(lbs_v1)" || return 1
  [ -z "$a$b" ]
}

if ! wait_for "${LB_WAIT:-300}" 15 "load balancers in $vpc to be deleted by Kubernetes" no_lbs; then
  warn "load balancers still present; force-deleting"
  for arn in $(lbs_v2); do run aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$arn"; done
  for name in $(lbs_v1); do run aws elb delete-load-balancer --region "$AWS_REGION" --load-balancer-name "$name"; done
  wait_for 300 15 "load balancers to disappear" no_lbs || die "load balancers still present in $vpc"
fi

for tg in $(aws elbv2 describe-target-groups --region "$AWS_REGION" --output json \
  | jq -r --arg v "$vpc" '.TargetGroups[] | select(.VpcId == $v) | .TargetGroupArn'); do
  run aws elbv2 delete-target-group --region "$AWS_REGION" --target-group-arn "$tg"
done

# k8s-* security groups made by the in-tree controller: drop rules that reference
# them from other groups, then delete them (retry while ENIs are still detaching).
sgs="$(aws ec2 describe-security-groups --region "$AWS_REGION" --output json \
  --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=k8s-*" | jq -r '.SecurityGroups[].GroupId')"
for sg in $sgs; do
  rules="$(aws ec2 describe-security-group-rules --region "$AWS_REGION" --output json \
    --filters "Name=group-id,Values=$(aws ec2 describe-security-groups --region "$AWS_REGION" --output json \
      --filters "Name=vpc-id,Values=$vpc" | jq -r '[.SecurityGroups[].GroupId] | join(",")')")"
  jq -r --arg sg "$sg" '.SecurityGroupRules[] | select(.ReferencedGroupInfo.GroupId == $sg)
    | "\(.GroupId) \(.SecurityGroupRuleId) \(.IsEgress)"' <<<"$rules" \
    | while read -r owner rule egress; do
        if [ "$egress" = true ]; then
          run aws ec2 revoke-security-group-egress --region "$AWS_REGION" --group-id "$owner" --security-group-rule-ids "$rule"
        else
          run aws ec2 revoke-security-group-ingress --region "$AWS_REGION" --group-id "$owner" --security-group-rule-ids "$rule"
        fi
      done
done

# ENIs owned by a load balancer linger "in-use" for a while after the LB is deleted
# and cannot be removed by hand; wait for them to go.
elb_enis() {
  aws ec2 describe-network-interfaces --region "$AWS_REGION" --output json \
    --filters "Name=vpc-id,Values=$vpc" \
    | jq -r '.NetworkInterfaces[] | select((.Description // "") | test("^ELB ")) | .NetworkInterfaceId'
}
no_elb_enis() { local e; e="$(elb_enis)" || return 1; [ -z "$e" ]; }
wait_for 600 15 "load balancer ENIs in $vpc to be released" no_elb_enis \
  || die "load balancer ENIs still present in $vpc: $(elb_enis | tr '\n' ' ')"

enis() {
  aws ec2 describe-network-interfaces --region "$AWS_REGION" --output json \
    --filters "Name=vpc-id,Values=$vpc" "Name=status,Values=available" \
    | jq -r '.NetworkInterfaces[].NetworkInterfaceId'
}
for eni in $(enis); do
  run aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni" || true
done

for sg in $sgs; do
  deleted=false
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if run aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg" 2>/dev/null; then
      deleted=true
      break
    fi
    for eni in $(enis); do aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni" 2>/dev/null || true; done
    sleep 15
  done
  [ "$deleted" = true ] || die "could not delete security group $sg (still in use?)"
done
log "lb-cleanup done for $vpc"
