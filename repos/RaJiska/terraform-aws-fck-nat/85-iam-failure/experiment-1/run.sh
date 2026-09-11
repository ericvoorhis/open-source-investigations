#!/usr/bin/env bash
# Run N trials of the unmodified fck-nat module and record what the ASG actually did.
#
#   ./run.sh <trials>
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

ROOT="$(cd "$(dirname "$0")" && pwd)"
PREFIX="fck-nat-exp"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# One directory per run, one per trial inside it, so results never interleave across runs.
RUN_DIR="$ROOT/results/${STAMP}"
RESULTS="$RUN_DIR/results.tsv"

# Precondition: AWSServiceRoleForAutoScaling must already exist.
#
# This test isolates ONE variable — a freshly created IAM role and instance profile — so everything else
# in the launch path has to already be settled. The service-linked role is created by the AutoScaling
# service during the first CreateAutoScalingGroup an account ever performs, so in an account that has
# never had an ASG, trial 1 would create it and be testing two new IAM objects at once.
#
# Abort rather than warn, because that mistake is irreversible: an account can only ever have its
# first-ever ASG once, and spending it here would consume a condition that cannot be restored.
SLR_CREATED_AT=$(aws iam get-role --role-name AWSServiceRoleForAutoScaling \
  --query 'Role.CreateDate' --output text 2>/dev/null)
if [ -z "$SLR_CREATED_AT" ]; then
  echo "ABORT: AWSServiceRoleForAutoScaling does not exist in this account." >&2
  echo "       This account has never created an Auto Scaling group, so trial 1 would create the" >&2
  echo "       service-linked role as a side effect and would not be testing what this test tests." >&2
  echo "       That condition is one-shot per account — do not spend it here." >&2
  exit 1
fi
SLR_ROLE_ID=$(aws iam get-role --role-name AWSServiceRoleForAutoScaling \
  --query 'Role.RoleId' --output text 2>/dev/null || echo "-")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "-")

# Ask the API which region it is actually talking to, rather than echoing $AWS_REGION. The CLI resolves
# a region from the env var, the profile, or a config default, so reading the variable can report
# "unset" for a run that in fact happened somewhere specific — and the region is provenance the results
# have to carry.
REGION=$(aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[0].RegionName' --output text 2>/dev/null || echo "-")

mkdir -p "$RUN_DIR"
printf 'trial\taccount_id\tregion\tslr_created_at\tslr_role_id\tprofile_created_at\tname\tapply_exit\tasg_created_at\tfirst_activity_at\tfirst_activity_status\tactivity_count\tfailed_activity_count\tfirst_activity_message\n' > "$RESULTS"

# Provenance for the run as a whole: the facts a reader needs to judge the results but that do not
# vary per trial. Tool versions matter because both the AWS provider's capacity-wait behaviour and the
# CLI's output shape have changed across releases.
{
  echo "started_at        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "account_id        $ACCOUNT_ID"
  echo "region            $REGION"
  echo "trials            $TRIALS"
  echo "slr_created_at    $SLR_CREATED_AT"
  echo "slr_role_id       $SLR_ROLE_ID"
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
  # Zero-padded so trial-10 sorts after trial-09 rather than after trial-01.
  TRIAL_DIR="$RUN_DIR/trial-$(printf '%02d' "$i")"
  mkdir -p "$TRIAL_DIR"
  echo "=== trial $i/$TRIALS  ($TF_VAR_trial_name) ==="

  terraform -chdir="$ROOT/stack" apply -auto-approve -input=false \
    > "$TRIAL_DIR/apply.log" 2>&1
  APPLY_EXIT=$?

  # Capture BEFORE destroy: scaling activity history is deleted along with the ASG, so this is the only
  # window in which the evidence exists. The raw JSON is the artefact; the row below is derived with
  # --query, so the harness needs nothing beyond the AWS CLI it already requires.
  aws autoscaling describe-scaling-activities --auto-scaling-group-name "$TF_VAR_trial_name" \
    > "$TRIAL_DIR/activities.json" 2>/dev/null

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

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$i" "$ACCOUNT_ID" "$REGION" "$SLR_CREATED_AT" "$SLR_ROLE_ID" "$PROFILE_CREATED_AT" "$TF_VAR_trial_name" "$APPLY_EXIT" "$CREATED" \
    "$FIRST_AT" "$FIRST_STATUS" "$COUNT" "$FAILED" "$MSG" >> "$RESULTS"
  echo "  apply_exit=$APPLY_EXIT first_activity=$FIRST_STATUS activities=$COUNT failed=$FAILED"

  terraform -chdir="$ROOT/stack" destroy -auto-approve -input=false \
    > "$TRIAL_DIR/destroy.log" 2>&1
  sweep
done

echo; echo "results: $RUN_DIR"
