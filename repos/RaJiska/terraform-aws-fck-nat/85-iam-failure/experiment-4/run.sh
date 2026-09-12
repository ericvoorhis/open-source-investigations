#!/usr/bin/env bash
# Run N trials of the unmodified fck-nat module in a FRESH account and record what the ASG did.
#
#   ./run.sh <trials>
#
# The inverse of experiment-1. Trial 1 must be the account's first-ever Auto Scaling group, so the
# AutoScaling service creates AWSServiceRoleForAutoScaling while handling that CreateAutoScalingGroup
# call and the launch fires seconds later against a role that has just come into existence.
#
# Trials 2..N are not repeats: after trial 1 the role exists and is ageing, so each later trial samples
# a different SLR age. One account therefore yields the first-ASG failure AND the recovery curve.
#
# Brings up a throwaway VPC once, runs N trials against it, tears it down at the end. Each trial creates
# a FRESH IAM role and instance profile (unique trial name), applies, captures the ASG's scaling
# activities, destroys, and sweeps anything the destroy could not see.
#
# Unique names per trial are what makes each trial a real test of propagation — reuse a name and every
# trial after the first runs against an already-propagated profile.
#
# The network is applied SEPARATELY and beforehand on purpose: Terraform parallelises independent
# resources, so building it inside a trial would delay the ASG behind the network rather than behind the
# IAM chain, giving the instance profile extra time to propagate and potentially masking the race.
#
# Requires: terraform, awscli, and AWS_PROFILE / AWS_REGION already pointing at the target account.
#
# No `set -e`: a failing apply is the outcome under test, so the loop must record it and carry on.
set -uo pipefail

TRIALS="${1:?number of trials}"

# How long to keep watching a failed trial's ASG for its own successful retry. Terraform gives up on the
# first failed activity; AWS does not, and that recovery time is what decides whether a shortened
# wait_for_capacity_timeout is survivable. 15 minutes is well past anything observed so far.
RECOVERY_WATCH_SECONDS="${RECOVERY_WATCH_SECONDS:-900}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="fck-nat-exp"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# One directory per run, one per trial inside it, so results never interleave across runs.
RUN_DIR="$ROOT/results/${STAMP}"
RESULTS="$RUN_DIR/results.tsv"

# Precondition: AWSServiceRoleForAutoScaling must NOT exist yet.
#
# The condition under test is an account's first-ever Auto Scaling group. If the role is already there,
# this account has had one, and no sequence of API calls restores the original state — deleting the role
# and letting it be recreated produces a DIFFERENT error ("AWS was not able to validate the provided
# access credentials") with a different, intermittent failure pattern, because the recycled ARN is
# cached against a RoleId that no longer exists.
#
# Abort rather than warn: a run here would look like the experiment while measuring something else.
if aws iam get-role --role-name AWSServiceRoleForAutoScaling >/dev/null 2>&1; then
  echo "ABORT: AWSServiceRoleForAutoScaling already exists in this account." >&2
  echo "       This test requires an account that has never created an Auto Scaling group." >&2
  echo "       That condition is one-shot and cannot be restored by deleting the role." >&2
  exit 1
fi
# Second half of the same precondition: the role must not exist AND must never have existed.
#
# A deleted role reports NoSuchEntity exactly like a virgin account, so the check above cannot tell them
# apart — and they are not the same condition. An account whose role was deleted and recreated fails with
# "AWS was not able to validate the provided access credentials", intermittently, because the recycled
# ARN is cached against a RoleId that no longer exists. That is a different phenomenon, and a run here
# would produce plausible rows measuring the wrong thing. It is the only failure mode in this harness
# that is silent rather than loud, which is why it earns an API call.
#
# Note the two event names: delete-service-linked-role is asynchronous, so CloudTrail records the API
# call as DeleteServiceLinkedRole and the deletion IAM actually performs, seconds later, as DeleteRole.
# Only the second is reachable through the ResourceName index. Event History retains 90 days.
SLR_DELETIONS=$(aws cloudtrail lookup-events --region us-east-1 --max-results 50 \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=AWSServiceRoleForAutoScaling \
  --query 'length(Events[?EventName==`DeleteRole` || EventName==`DeleteServiceLinkedRole`])' \
  --output text 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$SLR_DELETIONS" ]; then
  # Missing cloudtrail:LookupEvents should not block the run, but the results must say so — a reader
  # cannot otherwise tell a verified-virgin account from an unverified one.
  SLR_DELETIONS="unverified"
  echo "  WARNING: could not read CloudTrail, so a previously-deleted service-linked role cannot be" >&2
  echo "           ruled out. Recorded as unverified in run-meta.txt." >&2
elif [ "$SLR_DELETIONS" -gt 0 ] 2>/dev/null; then
  echo "ABORT: this account's AWSServiceRoleForAutoScaling was deleted at some point." >&2
  echo "       It reports NoSuchEntity like a fresh account, but is not one: a recreated role fails" >&2
  echo "       differently and intermittently. Those rows would not be comparable." >&2
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "-")

# Ask the API which region it is actually talking to, rather than echoing $AWS_REGION. The CLI resolves
# a region from the env var, the profile, or a config default, so reading the variable can report
# "unset" for a run that in fact happened somewhere specific — and the region is provenance the results
# have to carry.
REGION=$(aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[0].RegionName' --output text 2>/dev/null || echo "-")

mkdir -p "$RUN_DIR"
printf 'trial\taccount_id\tregion\tslr_before\tslr_created_at\tslr_role_id\tprofile_created_at\tname\tapply_exit\tapply_seconds\tasg_created_at\tfirst_activity_at\tfirst_activity_status\trecovery_at\tactivity_count\tfailed_activity_count\tfirst_activity_message\n' > "$RESULTS"

# Provenance for the run as a whole: the facts a reader needs to judge the results but that do not
# vary per trial. Tool versions matter because both the AWS provider's capacity-wait behaviour and the
# CLI's output shape have changed across releases.
{
  echo "started_at        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "account_id        $ACCOUNT_ID"
  echo "region            $REGION"
  echo "trials            $TRIALS"
  echo "slr_deletions     $SLR_DELETIONS"
  echo "terraform         $(terraform version -json 2>/dev/null | sed -n 's/.*"terraform_version": *"\([^"]*\)".*/\1/p' | head -1)"
  echo "aws_cli           $(aws --version 2>&1 | head -1)"
  echo "module            $(sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' "$ROOT/stack/main.tf" | head -1)"
} > "$RUN_DIR/run-meta.txt"

cat "$RUN_DIR/run-meta.txt" | sed 's/^/  /'
echo

# terraform destroy cannot clean up an ASG that exists in AWS but never entered state — which is exactly
# the failure under test. Sweep by prefix through the API instead.
sweep() {
  for asg in $(aws autoscaling describe-auto-scaling-groups \
        --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,\`${PREFIX}\`)].AutoScalingGroupName" \
        --output text 2>/dev/null); do
    echo "  sweeping orphaned ASG: $asg"
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$asg" --force-delete >/dev/null 2>&1
  done
  for profile in $(aws iam list-instance-profiles \
        --query "InstanceProfiles[?starts_with(InstanceProfileName,\`${PREFIX}\`)].InstanceProfileName" \
        --output text 2>/dev/null); do
    for role in $(aws iam get-instance-profile --instance-profile-name "$profile" \
          --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" >/dev/null 2>&1
    done
    aws iam delete-instance-profile --instance-profile-name "$profile" >/dev/null 2>&1
  done
  for role in $(aws iam list-roles \
        --query "Roles[?starts_with(RoleName,\`${PREFIX}\`)].RoleName" --output text 2>/dev/null); do
    for arn in $(aws iam list-attached-role-policies --role-name "$role" \
          --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" >/dev/null 2>&1
    done
    aws iam delete-role --role-name "$role" >/dev/null 2>&1
  done
  for arn in $(aws iam list-policies --scope Local \
        --query "Policies[?starts_with(PolicyName,\`${PREFIX}\`)].Arn" --output text 2>/dev/null); do
    aws iam delete-policy --policy-arn "$arn" >/dev/null 2>&1
  done
}

echo "=== bringing up the throwaway network ==="
terraform -chdir="$ROOT/network" init -input=false >/dev/null || exit 1
terraform -chdir="$ROOT/network" apply -auto-approve -input=false >/dev/null \
  || { echo "network apply failed"; exit 1; }

# Consumed by every terraform invocation below, so apply and destroy cannot drift apart.
export TF_VAR_vpc_id TF_VAR_subnet_id TF_VAR_trial_name
TF_VAR_vpc_id=$(terraform -chdir="$ROOT/network" output -raw vpc_id)
TF_VAR_subnet_id=$(terraform -chdir="$ROOT/network" output -raw subnet_id)
echo "  vpc=$TF_VAR_vpc_id subnet=$TF_VAR_subnet_id"

trap 'echo "=== tearing down the throwaway network ==="; terraform -chdir="$ROOT/network" destroy -auto-approve -input=false >/dev/null 2>&1' EXIT

terraform -chdir="$ROOT/stack" init -input=false >/dev/null || exit 1

for i in $(seq 1 "$TRIALS"); do
  TF_VAR_trial_name="${PREFIX}-$(date +%s)-${i}"

  # Read BEFORE the apply. This is the condition marker, not a timestamp for arithmetic: NONE means the
  # role does not exist yet, so this trial is the account's first-ever ASG. Only trial 1 should read NONE.
  SLR_BEFORE=$(aws iam get-role --role-name AWSServiceRoleForAutoScaling \
    --query 'Role.CreateDate' --output text 2>/dev/null || echo "NONE")
  [ -z "$SLR_BEFORE" ] && SLR_BEFORE="NONE"

  # Zero-padded so trial-10 sorts after trial-09 rather than after trial-01.
  TRIAL_DIR="$RUN_DIR/trial-$(printf '%02d' "$i")"
  mkdir -p "$TRIAL_DIR"
  echo "=== trial $i/$TRIALS  ($TF_VAR_trial_name)  slr_before=$SLR_BEFORE ==="

  # Timed, because the fix's cost is that Terraform now waits out the ASG's retry instead of erroring
  # early. Test 2's applies failed in seconds; a successful one here should take roughly a minute longer.
  APPLY_START=$(date +%s)
  terraform -chdir="$ROOT/stack" apply -auto-approve -input=false \
    > "$TRIAL_DIR/apply.log" 2>&1
  APPLY_EXIT=$?
  APPLY_SECONDS=$(( $(date +%s) - APPLY_START ))

  # Capture BEFORE destroy: scaling activity history is deleted along with the ASG, so this is the only
  # window in which the evidence exists. The raw JSON is the artefact; the row below is derived with
  # --query, so the harness needs nothing beyond the AWS CLI it already requires.
  aws autoscaling describe-scaling-activities --auto-scaling-group-name "$TF_VAR_trial_name" \
    > "$TRIAL_DIR/activities.json" 2>/dev/null

  # Terraform aborts on the first failed scaling activity, but the ASG keeps retrying and heals itself.
  # That recovery is invisible to a normal apply — it happens after Terraform has already exited — and it
  # is the number the maintainer's fix depends on, since ignore_failed_scaling_activities only helps if
  # the retry lands inside wait_for_capacity_timeout. Watch for it before destroying anything.
  RECOVERY_AT="-"
  if [ "$APPLY_EXIT" -ne 0 ]; then
    echo "  apply failed; watching for the ASG's own retry (up to ${RECOVERY_WATCH_SECONDS}s)"
    DEADLINE=$(( $(date +%s) + RECOVERY_WATCH_SECONDS ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      FOUND=$(aws autoscaling describe-scaling-activities --auto-scaling-group-name "$TF_VAR_trial_name" \
        --query 'sort_by(Activities[?StatusCode==`Successful`], &StartTime)[0].StartTime' \
        --output text 2>/dev/null)
      if [ -n "$FOUND" ] && [ "$FOUND" != "None" ]; then RECOVERY_AT="$FOUND"; break; fi
      sleep 15
    done
    echo "  recovery_at=$RECOVERY_AT"
    # Re-capture: the retries only exist in the activity list now, not at the time of the first capture.
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$TF_VAR_trial_name" \
      > "$TRIAL_DIR/activities.json" 2>/dev/null
  fi

  # Read AFTER the apply, because trial 1 creates the role during it — read beforehand it is NONE, and
  # the role's age at the launch attempt is exactly what this test measures. For every later trial this
  # is identical to SLR_BEFORE. Age is not computed here: both timestamps are recorded and the
  # subtraction happens in analyze.sh, so the harness needs nothing beyond terraform and the AWS CLI.
  SLR_CREATED_AT=$(aws iam get-role --role-name AWSServiceRoleForAutoScaling \
    --query 'Role.CreateDate' --output text 2>/dev/null || echo "-")
  [ -z "$SLR_CREATED_AT" ] && SLR_CREATED_AT="-"
  SLR_ROLE_ID=$(aws iam get-role --role-name AWSServiceRoleForAutoScaling \
    --query 'Role.RoleId' --output text 2>/dev/null || echo "-")
  [ -z "$SLR_ROLE_ID" ] && SLR_ROLE_ID="-"

  # The instance profile's own creation timestamp, from IAM, captured before the destroy removes it.
  #
  # This is the anchor for #85's hypothesis: the profile's age at the launch attempt is what has to be
  # short for instance-profile propagation to be the cause. Recorded as a timestamp rather than derived
  # from the apply log's "Creation complete after 6s" lines, which give durations and force an inference
  # about ordering; IAM's CreateDate is direct.
  PROFILE_CREATED_AT=$(aws iam get-instance-profile --instance-profile-name "$TF_VAR_trial_name" \
    --query 'InstanceProfile.CreateDate' --output text 2>/dev/null || echo "-")
  [ -z "$PROFILE_CREATED_AT" ] && PROFILE_CREATED_AT="-"

  CREATED=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$TF_VAR_trial_name" \
    --query 'AutoScalingGroups[0].CreatedTime' --output text 2>/dev/null || echo "-")

  # The message is last because `read` assigns the remainder of the line to the final variable, so a
  # StatusMessage containing spaces stays intact instead of spilling into extra fields.
  read -r FIRST_AT FIRST_STATUS COUNT FAILED MSG <<<"$(
    aws autoscaling describe-scaling-activities --auto-scaling-group-name "$TF_VAR_trial_name" --query '[
      sort_by(Activities, &StartTime)[0].StartTime,
      sort_by(Activities, &StartTime)[0].StatusCode,
      length(Activities),
      length(Activities[?StatusCode==`Failed`]),
      sort_by(Activities, &StartTime)[0].StatusMessage
    ]' --output text 2>/dev/null || printf -- '-\t-\t0\t0\t-'
  )"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$i" "$ACCOUNT_ID" "$REGION" "$SLR_BEFORE" "$SLR_CREATED_AT" "$SLR_ROLE_ID" "$PROFILE_CREATED_AT" "$TF_VAR_trial_name" "$APPLY_EXIT" "$APPLY_SECONDS" "$CREATED" \
    "$FIRST_AT" "$FIRST_STATUS" "$RECOVERY_AT" "$COUNT" "$FAILED" "$MSG" >> "$RESULTS"
  echo "  apply_exit=$APPLY_EXIT (${APPLY_SECONDS}s) first_activity=$FIRST_STATUS activities=$COUNT failed=$FAILED"

  terraform -chdir="$ROOT/stack" destroy -auto-approve -input=false \
    > "$TRIAL_DIR/destroy.log" 2>&1
  sweep
done

echo; echo "results: $RUN_DIR"
