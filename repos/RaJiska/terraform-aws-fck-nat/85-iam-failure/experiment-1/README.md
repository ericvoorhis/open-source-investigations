# Test 1 — baseline, fresh IAM role per trial

Runs unmodified `terraform-aws-fck-nat` v1.6.1 N times in one account, giving each trial a brand-new
IAM role and instance profile, and records what the ASG's first scaling activity did.

## Run

```sh
export AWS_PROFILE=<profile> AWS_REGION=<region>
./run.sh 10
```

## Precondition

`AWSServiceRoleForAutoScaling` must already exist in the account, and the run aborts if it does not.

This test isolates one variable — a freshly created IAM role and instance profile — so everything else
in the launch path has to be settled already. AWS creates that service-linked role during the first
`CreateAutoScalingGroup` an account ever performs, so in an account that has never had an Auto Scaling
group, trial 1 would create it as a side effect and be testing two new IAM objects at once.

It aborts rather than warns because the mistake is irreversible: an account has its first-ever ASG only
once.

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
    activities.json      raw describe-scaling-activities output
    apply.log
    destroy.log
  trial-02/
  ...
```

The raw JSON is the evidence; the TSV is derived from it with `--query` and is only a convenience.

Columns: `trial`, `account_id`, `region`, `slr_created_at`, `slr_role_id`, `name`, `apply_exit`,
`asg_created_at`, `first_activity_at`, `first_activity_status`, `activity_count`,
`failed_activity_count`, `first_activity_message`.

Everything identifying the environment is read from the account at startup rather than supplied, so a
run cannot be mislabelled. `region` comes from the API rather than `$AWS_REGION`, because the CLI also
resolves a region from the profile or a config default — reading the variable would report `unset` for a
run that did happen somewhere specific.

Region and account are repeated on every row so the TSVs stay self-describing when concatenated across
runs; `run-meta.txt` carries the rest, which cannot vary within a run.

## Requirements

`terraform` >= 1.5 and `awscli`, with credentials for the target account already in the environment.
Provider versions are pinned by the committed `.terraform.lock.hcl` files.
