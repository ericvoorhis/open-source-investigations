# Test 4 — the maintainer's proposed fix

Tests [the maintainer's `asg-iam-propagation-race` branch](https://github.com/RaJiska/terraform-aws-fck-nat/tree/asg-iam-propagation-race)
in fresh accounts, under the exact condition that fails in [test 2](../experiment-2).

The branch adds two arguments to `aws_autoscaling_group.main`:

```hcl
wait_for_capacity_timeout        = "5m"    # down from the provider default of 10m
ignore_failed_scaling_activities = true
```

## What the fix does, and what it depends on

`ignore_failed_scaling_activities` does **not** suppress the failure. Per the AWS provider it stops a
failed scaling activity from *aborting* the capacity wait — Terraform keeps waiting until desired capacity
is reached or `wait_for_capacity_timeout` expires.

So the ASG's first launch should still fail exactly as in test 2. What should change is Terraform's
reaction: instead of erroring on the failed activity, it waits, the ASG retries, and the apply succeeds.

That makes the fix depend on **the ASG's own retry landing inside 5 minutes**. Test 2 measured that
recovery at 59.83s, 63.40s and 64.85s across three accounts — comfortably inside — but that is the thing
this test checks rather than assumes. The maintainer shortened the timeout from the 10-minute default, so
a recovery slower than 5 minutes would convert a fast, clear failure into a slow, confusing one.

## What a working fix looks like

| signal | expected |
| --- | --- |
| `apply` | `ok` on every trial, including the first |
| `activity` on trial 1 | still `Failed` — `Authentication Failure` |
| `activities` on trial 1 | `2` — the failure and the ASG's own retry |
| `apply_time` on trial 1 | ~60s longer than later trials |

**A run with no failed launch at all proves nothing** — it would mean the account had already created an
Auto Scaling group and the condition was never present. `analyze.sh` reports that count for exactly this
reason.

## Run

```sh
export AWS_PROFILE=<profile for a fresh account> AWS_REGION=<region>
caffeinate -ims ./run.sh 10
```

One account per invocation, three accounts total, as in test 2. Account provisioning and the precondition
are identical — see [test 2's README](../experiment-2/README.md#provisioning-a-fresh-account).

## Precondition

`AWSServiceRoleForAutoScaling` must **not** exist and must never have existed. Same guard as tests 2 and
3, and it matters more here: the whole point is to exercise the failure, so an account that cannot
produce it yields a green run that means nothing.

## What differs from test 2

Only the module source. Same inputs, same instance type, same harness, same guards.

```
experiment-2   source = "RaJiska/fck-nat/aws", version = "1.6.1"
experiment-4   source = "git::https://github.com/RaJiska/terraform-aws-fck-nat.git?ref=asg-iam-propagation-race"
```

## Output

Same layout as test 2, plus an `apply_seconds` column — the duration of each `terraform apply`. That is
the cost of the fix: the first apply now waits out the ASG's retry rather than erroring after a few
seconds.

`./analyze.sh` reports applies that failed, trials with a failed launch, and the first-versus-later apply
durations. `./timeline.sh` works as in test 2.

## Requirements

`terraform` >= 1.5 and `awscli`, with credentials for the target account already in the environment. The
module comes from a git ref rather than the registry, so `terraform init` needs network access to GitHub.
