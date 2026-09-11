# Test 3 — pre-create the service-linked role, then wait

Isolates the cause. [Test 2](../experiment-2) showed that an account's first-ever Auto Scaling group fails, and
that `AWSServiceRoleForAutoScaling` is created by AutoScaling during that same `CreateAutoScalingGroup`
call. What it could not show is *why*, because two explanations fit every observation equally:

- the role's **age** is the mechanism — it is created and used in the same instant, and cannot yet be
  assumed, or
- the role is a **marker** — some other once-per-account initialisation happens on the first ASG, and the
  role merely happens to be created at the same moment.

Nothing in test 2 can separate those, because the role does not exist until the call that immediately
uses it. There is no gap to observe.

This test creates the gap. `run.sh` creates the role itself, waits, and only then applies the module —
so the account's first ASG meets a role that is already minutes old.

| outcome | conclusion |
| --- | --- |
| apply **succeeds** | the role's age is the mechanism, and pre-creating it is a genuine fix |
| apply **fails** | the role is a marker; something else initialises on the first ASG, still unidentified |

Trial 1 is the experiment. Later trials only re-confirm what test 1 already showed.

## Run

```sh
export AWS_PROFILE=<profile for a fresh account> AWS_REGION=<region>
caffeinate -ims ./run.sh 1
```

`SLR_WAIT_SECONDS` defaults to 300. Test 2 measured the role becoming usable 63–67s after creation
across three accounts, so five minutes is comfortably past it — the point is to be unambiguous, not to
find the minimum. The network apply counts toward the wait rather than being added to it.

Account provisioning is the same as test 2 — see [its README](../experiment-2/README.md#provisioning-a-fresh-account).

## Precondition

Identical to test 2: `AWSServiceRoleForAutoScaling` must **not** exist and must never have existed, and
the run aborts on either. The condition is one-shot per account and cannot be restored by deleting the
role — a deleted-and-recreated role fails differently and intermittently, which would look like a result
and mean nothing.

## What differs from test 2

Only the sequence. Same module, same version, same inputs, same harness.

```
experiment-2   CreateAutoScalingGroup ─┬─ AWS creates the SLR
                                 └─ launch attempted ~4s later      -> FAILS

experiment-3   we create the SLR
         ... 300s ...
         CreateAutoScalingGroup ─── launch attempted                -> ?
```

## Output

Same layout and columns as test 2, plus `slr_wait_seconds` in `run-meta.txt`. `slr_before` reads a real
timestamp on every row rather than `NONE` on the first, because the role exists before any trial runs —
that is the manipulation.

`./analyze.sh` and `./timeline.sh` work as they do in test 2.

## Requirements

`terraform` >= 1.5 and `awscli`, with credentials for the target account already in the environment.
Provider versions are pinned by the committed `.terraform.lock.hcl` files.
