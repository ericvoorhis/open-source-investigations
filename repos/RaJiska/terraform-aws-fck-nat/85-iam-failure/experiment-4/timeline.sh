#!/usr/bin/env bash
# Print an ordered timeline of trial 1 — the account's first-ever ASG.
#
#   ./timeline.sh [run-directory]     (defaults to the most recent run under results/)
#
# Merges two sources, because neither is sufficient alone:
#
#   CloudTrail  which API calls happened and which identity made them. IAM is a global service, so
#               CreateServiceLinkedRole is recorded in us-east-1 while everything else is in the region
#               under test; both are queried.
#   activities  AutoScaling's own scaling-activity records, from the run's activities.json. These are
#               NOT API calls and appear nowhere in CloudTrail — they are the only place the
#               "Authentication Failure" message exists, and the only rows with real sub-second
#               precision. The ASG is destroyed at the end of each trial and its activity history goes
#               with it, so the captured file is the sole surviving copy.
#
# Nothing is filtered. An earlier version dropped the caller's Describe* polling as noise, which was a
# mistake: that polling is what proves the 63-second gap is real rather than missing telemetry, and the
# session names in it show Terraform giving up (aws-go-sdk-*) and the harness's recovery watch taking
# over (botocore-session-*) two seconds later.
#
# Two artefacts to know when reading the output:
#
#   1. CloudTrail's eventTime is the time the call COMPLETED (documented). Calls a service makes while
#      handling your request therefore carry EARLIER timestamps than the request that caused them —
#      CreateAutoScalingGroup appears after CreateServiceLinkedRole and after the dry-run RunInstances,
#      both of which it triggered. Causality comes from the invokedBy column, not from the order.
#   2. CloudTrail is second-granularity, rendered here as .000. Only the (scaling activity) rows carry
#      genuine sub-second precision.
#
# The failing call itself is absent. There is no CloudTrail event at the moment of failure — only the
# scaling activity recording that a launch attempt failed. What the log shows is that the successful
# launch begins with AssumeRole into AWSServiceRoleForAutoScaling, and that no such assume appears
# before the failure.
#
# Requires jq.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN="${1:-$(ls -d "$ROOT"/results/*/ 2>/dev/null | tail -1)}"
[ -n "$RUN" ] && [ -f "$RUN/results.tsv" ] || { echo "no results.tsv found" >&2; exit 1; }

read -r ACCT REGION SLR FIRST REC <<<"$(awk -F'\t' 'NR==2 {print $2"\t"$3"\t"$5"\t"$12"\t"$14}' "$RUN/results.tsv")"

# A trial that passed has no recovery_at, because there was nothing to recover from. End the window at
# the launch instead — which is the whole story in that case.
if [ "$REC" = "-" ]; then
  END="$FIRST"
  echo "  (trial 1 passed; window ends at the successful launch)"
else
  END="$REC"
fi

CUR=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
[ "$CUR" = "$ACCT" ] || { echo "ABORT: AWS_PROFILE is account ${CUR:-none}, this run is $ACCT." >&2; exit 1; }

echo "  run $(basename "$RUN")   account $ACCT   region $REGION"
echo
printf '  %-23s  %-25s  %-31s  %s\n' "timestamp" "invokedBy" "event" "identity / detail"
{
  # Rendered as annotation lines rather than table rows: these are not API calls, so giving them an
  # invokedBy or an identity would be a category error. They still sort into place by timestamp.
  jq -r '.Activities[]
         | ((.StartTime | sub("\\+00:00$"; "") | .[0:23]) + "\u0001launch ")
           + (if .StatusCode == "Successful" then "SUCCEEDED" else (.StatusCode | ascii_upcase) end)
           + ": " + (.StatusMessage // .Description)' "$RUN/trial-01/activities.json" 2>/dev/null

  for R in us-east-1 "$REGION"; do
    aws cloudtrail lookup-events --region "$R" --start-time "$SLR" --end-time "$END" \
      --max-results 50 --output json 2>/dev/null \
    | jq -r '.Events[].CloudTrailEvent | fromjson
        | ((.eventTime | sub("Z$"; ".000")) + (" " * 23))[0:23] + "  "
          + (((.userIdentity.invokedBy // "-") + (" " * 25))[0:25]) + "  "
          + ((.eventName + (" " * 31))[0:31]) + "  "
          + ((.userIdentity.arn // .userIdentity.type) | split("/") | .[-2:] | join("/"))'
  done
} | sort | awk -F'\001' '
    # Scaling activities are not API calls, so they are set apart from the table rather than pretending
    # to have an invokedBy and an identity. Sorting happens first; this only reformats.
    NF == 2 { printf "\n      %s  %s\n\n", substr($1, 12, 12), $2; next }
    { print "  " $0 }'
