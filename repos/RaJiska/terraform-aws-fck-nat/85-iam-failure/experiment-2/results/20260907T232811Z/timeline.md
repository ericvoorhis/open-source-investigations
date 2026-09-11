# Trial 1 timeline — account `399855128207`, `us-west-2`

Run `20260907T232811Z`, trial 1: the account's first-ever Auto Scaling group.

Merged from CloudTrail (both `us-east-1` and `us-west-2` — IAM is global, so `CreateServiceLinkedRole`
is only in the former) and the ASG's own scaling activities from `trial-01/activities.json`.

`CreateAutoScalingGroup` is the only call made directly. Every row carrying an `invokedBy` was made by
AutoScaling while handling it, under the caller's own session.

| time | invokedBy | event | identity |
|---|---|---|---|
| `23:29:20.000` | - | `DescribeLaunchTemplateVersions` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:20.000` | - | `DescribeLaunchTemplates` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:20.000` | - | `DescribeLaunchTemplates` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:20.000` | - | `DescribeLaunchTemplates` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:21.000` | autoscaling.amazonaws.com | `CreateServiceLinkedRole` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:21.000` | autoscaling.amazonaws.com | `DescribeAvailabilityZones` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:21.000` | autoscaling.amazonaws.com | `DescribeLaunchTemplateVersions` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:21.000` | autoscaling.amazonaws.com | `DescribeSubnets` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:21.000` | autoscaling.amazonaws.com | `GetSecurityGroupsForVpc` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:21.000` | autoscaling.amazonaws.com | `RunInstances` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:22.000` | - | `CreateAutoScalingGroup` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:22.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:22.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:22.000` | autoscaling.amazonaws.com | `DescribeInstanceTypes` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:22.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:22.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:22.000` | autoscaling.amazonaws.com | `DescribeVpcs` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:23.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:23.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:24.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:24.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |

> **❌ `23:29:24.426` — launch FAILED**
> `Authentication Failure. Launching EC2 instance failed.`
>
> The service-linked role was **4.4 seconds old**. There is no CloudTrail event for the failing call —
> this is from the ASG's scaling activities, which are not API calls and appear nowhere in the log above.

| time | invokedBy | event | identity |
|---|---|---|---|
| `23:29:26.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788823747092418000` |
| `23:29:27.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/botocore-session-1788823300` |
| `23:29:27.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/botocore-session-1788823300` |
| `23:29:43.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/botocore-session-1788823300` |
| `23:29:59.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/botocore-session-1788823300` |
| `23:30:15.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/botocore-session-1788823300` |
| `23:30:27.000` | autoscaling.amazonaws.com | `AssumeRole` | `AWSService` |
| `23:30:29.000` | autoscaling.amazonaws.com | `CreateFleet` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `23:30:29.000` | autoscaling.amazonaws.com | `RunInstances` | `AWSServiceRoleForAutoScaling/AutoScaling` |

> **✅ `23:30:29.276` — launch SUCCEEDED**
> `Launching a new EC2 instance: i-067c0832489e5918a`
>
> Preceded by the first successful `AssumeRole` into `AWSServiceRoleForAutoScaling`, **66 seconds** after
> the role was created. Nothing was retried in the interval — AutoScaling made no attempt at all, while
> the caller's `DescribeScalingActivities` polling continued unbroken, so the gap is real rather than
> missing telemetry.

## Reading notes

- **CloudTrail's `eventTime` is when a call *completed***, so calls a service makes while handling your
  request carry earlier timestamps than the request itself. That is why `CreateAutoScalingGroup` appears
  below things it caused. Causality is in the `invokedBy` column, not in the order.
- **CloudTrail is second-granularity**, rendered here as `.000`. Only the two callouts carry real
  sub-second precision, from AutoScaling's own records.
- **Rows within the same second are unordered.** They are sorted secondarily by event name so the table
  is reproducible, but that ordering is arbitrary — consecutive rows in one second are not necessarily
  consecutive events.
- **Two sessions appear.** `aws-go-sdk-*` is Terraform, which stops polling at `23:29:26`, two seconds
  after the failure. `botocore-session-*` is the harness's recovery watch, which continues to the end.

Regenerate with `../../timeline.sh results/20260907T232811Z`.
