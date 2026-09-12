# Test 2 — baseline in fresh accounts

The inverse of [experiment-1](../experiment-1). Runs unmodified `terraform-aws-fck-nat` v1.6.1 in accounts that have
**never created an Auto Scaling group**, so trial 1 is the account's first — and the AutoScaling service
creates `AWSServiceRoleForAutoScaling` while handling that `CreateAutoScalingGroup` call.

One account per run, several accounts total. The argument is the **shape** of the results, not a failure
rate: if the account's first-ever ASG is what fails, trial 1 fails in every account and no later trial
does. A race condition would scatter failures through the sequence instead.

## Provisioning a fresh account

The harness deliberately does **not** create accounts. Creating one is close to irreversible — closing
it takes 90 days to free the organisation's quota slot — and account creation needs organisation-level
credentials that the measurement itself has no business holding. So provisioning is a separate,
deliberate act.

From the organisation's management account:

```sh
aws organizations create-account \
  --email <unique-address> --account-name "fck-nat-test-a" \
  --query 'CreateAccountStatus.Id' --output text

aws organizations describe-create-account-status \
  --create-account-request-id <id> \
  --query 'CreateAccountStatus.[State,AccountId]' --output text
```

Each account needs its own root email address. Creation is fast — a few seconds — but "account exists"
is not "account usable": `OrganizationAccountAccessRole` is created inside it for you to assume, and
that role propagates like any other, so expect `sts assume-role` to fail briefly afterwards.

### Use a profile, not exported credentials

```ini
# ~/.aws/config
[profile fck-nat-test-a]
role_arn       = arn:aws:iam::<new-account-id>:role/OrganizationAccountAccessRole
source_profile = <your management-account profile>
region         = us-west-2
```

This matters more than it looks. `sts assume-role` issues credentials valid for **one hour** by default,
and a six-trial run approaches that — each failed trial adds its recovery watch on top of the apply and
destroy. Credentials expiring mid-run would abandon the run with resources still standing. A config
profile lets both the AWS CLI and the Terraform provider refresh on their own, so run length stops
mattering.

### Confirm the account is actually fresh

```sh
AWS_PROFILE=fck-nat-test-a aws iam get-role --role-name AWSServiceRoleForAutoScaling
```

`NoSuchEntity` is what you want. Anything else means the account has already created an Auto Scaling
group — most likely an organisation baseline, a StackSet, or a landing-zone pipeline got there first —
and its first-ASG condition is spent. `run.sh` aborts on this too, but checking first costs a second
rather than a provisioning cycle.

## Run

```sh
export AWS_PROFILE=fck-nat-test-a AWS_REGION=us-west-2
caffeinate -ims ./run.sh 10
```

Ten trials spans roughly eighteen minutes of service-linked-role age, which brackets the transition with
room on both sides — `shared` failed at 63s and first succeeded at 8:13, so the middle of that range is
the least-mapped part and worth sampling densely. The account's first-ASG condition is one-shot, so
there is no going back to add samples later.

`caffeinate -ims` keeps the machine awake for the duration and releases when the run exits. `-s` only
applies on AC power, and closing the lid still sleeps regardless.

One account per invocation. Repeat for each:

```sh
for p in fck-nat-test-a fck-nat-test-b fck-nat-test-c; do
  AWS_PROFILE=$p caffeinate -ims ./run.sh 10
done
```

Runs are independent — separate accounts, separate VPCs, prefix sweeps scoped to their own account — so
they can equally be run concurrently in separate terminals.

Timing, measured from experiment-1: about 106s per trial (min 84s, max 122s) plus ~40s of setup, so ten trials
is roughly 18 minutes. Failing trials are not slower — a failed apply aborts early, about nine seconds
after the failed scaling activity, where a successful one waits for the instance to reach InService. What
they add is the recovery watch, 60–90s each. Expect ~20 minutes per account, so about an hour for three
sequentially or ~20 minutes concurrently.

## Precondition

`AWSServiceRoleForAutoScaling` must **not** exist *and must never have existed*. The run aborts on
either.

The condition under test is an account's first-ever ASG, and it is one-shot: no sequence of API calls
restores it. Deleting the role and letting it be recreated is *not* equivalent — that produces
`AWS was not able to validate the provided access credentials` with an intermittent failure pattern,
rather than the `Authentication Failure` this test is about, because the recycled ARN is cached against
a `RoleId` that no longer exists.

The second half of the check is why it takes an API call. A *deleted* role reports `NoSuchEntity`
exactly like a virgin account, so `get-role` alone cannot separate them — and they are different
conditions producing different errors. The harness therefore also queries CloudTrail for
`DeleteRole` / `DeleteServiceLinkedRole` events against that role name (~0.7s, once per run, free) and
aborts if it finds any.

This is the only silent failure mode in the harness. Every other way a run can go wrong — a CIDR
collision, missing permissions, a bad AMI — fails loudly during `terraform apply`. A previously-deleted
role instead produces a full set of plausible rows measuring a different phenomenon.

Without `cloudtrail:LookupEvents` the run continues but records `slr_deletions unverified` in
`run-meta.txt`, so the results say whether the condition was actually confirmed.

The guard also catches a subtler mistake: anything in an organisation's account baseline that happens to
create an ASG would consume the condition before you got to it.

## Why more than one trial

Trials 2..N are not repeats. After trial 1 the service-linked role exists and begins ageing, so each
later trial launches against an older role, and `slr_created_at` paired with `first_activity_at` gives
its age at each launch attempt. One account therefore yields the first-ASG failure *and* the recovery
gradient.

Trial 1's `slr_before` reads `NONE`, because the role does not exist until that trial's apply creates it.
Its `slr_created_at` is read after the apply, which is what makes the age computable for that trial.

Note the interval between trials is not uniform: a failed trial waits for its recovery watch before the
next begins, so early trials are spaced further apart than later ones.

## Recovery watch

When an apply fails, Terraform's capacity wait aborts on the failed scaling activity and the apply
errors — but the ASG is still there, still has an unmet `desired_capacity`, and AutoScaling keeps
scheduling launches. That recovery is invisible to a normal apply, because it happens after Terraform
has already exited.

Each failed trial is therefore left standing and polled every 15s until a `Successful` activity appears,
and `recovery_at` records it. The recorded value is AWS's own `StartTime` on that activity, so it is
exact — the poll interval only bounds how long the harness lingers before the next trial, not the
precision of the measurement.

That number decides the maintainer's proposed fix. `ignore_failed_scaling_activities` only helps if the
retry lands inside `wait_for_capacity_timeout`, which his branch shortens to 5 minutes from the
10-minute default. `analyze.sh` states the comparison directly.

Default watch is 900s; override with `RECOVERY_WATCH_SECONDS`.

## Analysis

```sh
./analyze.sh                     # every run, combined — one account per run
./analyze.sh results/<stamp>     # a single run
```

| column | from → to | what it tells you |
| --- | --- | --- |
| `slr_age_at_launch` | `slr_created_at` → `first_activity_at` | how old the service-linked role was when AutoScaling tried to use it |
| `profile_age` | `profile_created_at` → `first_activity_at` | how old the *instance profile* was — #85's hypothesis, and experiment-1's subject |
| `asg->launch` | `asg_created_at` → `first_activity_at` | launch latency; the control showing the race window was exercised |
| `self_heal` | `first_activity_at` → `recovery_at` | how long the ASG took to recover on its own |

A `*` marks the account's first-ever ASG. The summary states the shape — how many accounts, whether
trial 1 failed in each, whether any later trial failed — and the self-heal range against the 5-minute
budget.

## CloudTrail timeline

```sh
export AWS_PROFILE=<the account that run used>
./timeline.sh                     # most recent run
./timeline.sh results/<stamp>     # a specific one
```

Merges every CloudTrail event between the service-linked role's creation and the ASG's recovery with
the scaling activities from `activities.json`, taking the window from `results.tsv`. It aborts if
`AWS_PROFILE` points at a different account than the run used, since that would silently query the
wrong trail.

Both regions are queried and neither alone tells the story: IAM is a global service, so
`CreateServiceLinkedRole` is recorded in `us-east-1`, while everything that fails and recovers is in
the region under test. The scaling activities appear in neither — they are AutoScaling's own records,
they are the only place the error message exists, and they die with the ASG, so the captured file is
the only surviving copy.

**Nothing is filtered, deliberately.** The caller's `Describe*` polling looks like noise but is what
proves the ~63-second gap is real rather than missing telemetry, and its session names show Terraform
giving up (`aws-go-sdk-*`) two seconds after the failed activity, with the recovery watch
(`botocore-session-*`) taking over.

Two artefacts to know when reading it. CloudTrail's `eventTime` is the time a call **completed**, so
calls a service makes while handling your request carry *earlier* timestamps than the request that
caused them — causality comes from the `invokedBy` column, not from the order. And CloudTrail is
second-granularity, shown as `.000`; only the activity rows carry real sub-second precision.

The failing call is **absent**. No CloudTrail event exists at the moment of failure — only the scaling
activity recording that a launch attempt failed. What the log establishes is that the successful launch
begins with an `AssumeRole` into `AWSServiceRoleForAutoScaling`, and that no such assume appears before
the failure.

The shape, with the nesting drawn as it actually is rather than as the log orders it:

```
CreateAutoScalingGroup                          <- the one call you make
  |
  +- CreateServiceLinkedRole    (us-east-1)     <- AWS creates the role, mid-request
  +- DescribeSubnets, DescribeVpcs, ...         <- validates your config
  +- RunInstances --dry-run                     <- "would have succeeded"
  |                                                all under YOUR session
  v
ASG exists, first launch attempted
  scaling activity: Failed - Authentication Failure       ~4s after the role was created
       ...  ~63 seconds, nothing from AutoScaling  ...
  AssumeRole -> AWSServiceRoleForAutoScaling              <- first successful assume
  CreateFleet, RunInstances  as the service role
  scaling activity: Successful
```

AutoScaling validates the launch using the caller's credentials, which is why
`CreateAutoScalingGroup` returns success — but performing the launch requires assuming the
service-linked role, and that does not work until the role is roughly a minute old.

## What it creates and cleans up

Per run: one throwaway VPC (`10.99.0.0/16`), applied once before the first trial and destroyed on exit.

Per trial: one `fck-nat` stack named `fck-nat-exp-<unix-epoch>-<trial-index>` — IAM role, instance
profile, policy, launch template, security group, ENI, and an ASG of one `t4g.nano`. Destroyed after the
activities are captured, then swept by name prefix to catch anything that never entered Terraform state
(which is the normal outcome when the apply fails).

## Output

One directory per run, one per trial inside it:

```
results/<stamp>/
  run-meta.txt           account, region, tool versions, module version
  results.tsv            one row per trial
  trial-01/
    activities.json      raw describe-scaling-activities output, re-captured after the recovery watch
    apply.log
    destroy.log
  trial-02/
  ...
```

Columns: `trial`, `account_id`, `region`, `slr_before`, `slr_created_at`, `slr_role_id`,
`profile_created_at`, `name`, `apply_exit`, `asg_created_at`, `first_activity_at`,
`first_activity_status`, `recovery_at`, `activity_count`, `failed_activity_count`,
`first_activity_message`.

Ages are not computed by the harness — the timestamps are recorded and the subtraction happens in
`analyze.sh`, so nothing beyond terraform and the AWS CLI is required to produce the data.

## Requirements

`terraform` >= 1.5 and `awscli`, with credentials for the target account already in the environment.
Provider versions are pinned by the committed `.terraform.lock.hcl` files.
