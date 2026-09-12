# #85 — IAM role race condition but not from a role within the module

This directory contains experiments for reproducing [RaJiska/terraform-aws-fck-nat#85](https://github.com/RaJiska/terraform-aws-fck-nat/issues/85) and validating a fix for it. I've committed results for each experiment within their corresponding subdirectory under this one.

I show that:
- The root cause behind the reported Terraform apply error from the ASG capacity wait authentication failure is a race condition between the `AWSServiceRoleForAutoScaling` service-linked role (SLR) being automatically created and the first ASG attempting to use it. The `AWSServiceRoleForAutoScaling` SLR does not exist in a fresh account until it is either manually created or created automatically as part of the AutoScaling service handling our first `CreateAutoScalingGroup` call. The race condition unfolds when the first ASG attempts a launch with the fresh SLR before it is propagated.
- The maintainer's fix on the `asg-iam-propagation-race` branch [mentioned in this issue comment](https://github.com/RaJiska/terraform-aws-fck-nat/issues/85#issuecomment-5327877194) resolves this issue. Across 6 deployments on fresh accounts, the slowest ASG self-heal I saw was 65.61 seconds, meaning 5 minutes for the timeout leaves 4.6x headroom (the overall range of self-heal times was 59.83 to 65.61 seconds).

After testing, I am not able to recreate an authentication failure related to IAM propagation delays for the `terraform-aws-fck-nat`'s `aws_iam_role.main` or `aws_iam_instance_profile.main` resources. In the first 3 experiments, I deploy v1.6.1 of the `terraform-aws-fck-nat` module 41 times (each fully creating every resource in the module), and the deployment is successful in 38 of the deployments (exclusively in cases where the `AWSServiceRoleForAutoScaling` SLR already exists). The remaining 3 failures for v1.6.1 only happen on fresh accounts where the `AWSServiceRoleForAutoScaling` SLR didn't exist yet prior to deploying the module. In experiment 4, I deploy the `asg-iam-propagation-race` branch 30 times and witness no Terraform apply failures and graceful ASG failure handling in the first apply of all 3 fresh accounts tested.

Side note that you may consider when reading through this write-up: You can force an apply failure by deleting `AWSServiceRoleForAutoScaling` in an account that already has it and then deploying `terraform-aws-fck-nat`, but the resulting error is not a plain `Authentication Failure` as reported. In this scenario, you get a `AWS was not able to validate the provided access credentials` error, and the failure pattern is more intermittent, probably because of AWS caching the previous (and now deleted) `AWSServiceRoleForAutoScaling` reference in their backend. You can wait out the intermittent caching errors (I haven't measured exactly how long they last), but it's easier to just run it on fresh accounts (if you have the account quota to burn).

## Experiment 1

### Setup

On an existing account that has previously been used with an ASG and already has a `AWSServiceRoleForAutoScaling` SLR, I will deploy v1.6.1 of `terraform-aws-fck-nat` 10 times, using uniquely named IAM roles for each deployment and report success or failure on the apply. I will use uniquely named IAM roles so that I'm truly testing new role creation propagation each time.

### Results

10/10 trials were successful with zero failed scaling activities. The age of `aws_iam_instance_profile.main` varied between 16.57 and 21.32 seconds at time of ASG launch, the range of time between the ASG being created and the first EC2 launch is 3.08 to 7.46 seconds, and the random test environment account that I used had a 25 day old `AWSServiceRoleForAutoScaling` SLR. The instance profile age appears to be primarily the result of the [AWS provider's internal propagation wait](https://github.com/hashicorp/terraform-provider-aws/blob/v6.63.0/internal/service/iam/instance_profile.go#L374-L386) during the creation of the [`aws_iam_instance_profile.main`](https://github.com/RaJiska/terraform-aws-fck-nat/blob/main/iam.tf#L1) resource and delays from the creation of [`aws_launch_template.main`](https://github.com/RaJiska/terraform-aws-fck-nat/blob/main/ec2.tf#L62).

## Experiment 2

### Setup

Since experiment 1 didn't yield an IAM propagation error related to the module's IAM resources, I'm going to run the same experiment format (10 trials of deploying v1.6.1 of `terraform-aws-fck-nat`) but over 3 new accounts with no prior activity (30 trials total, 10 per run). This will help us understand how much being a "fresh" account has to do with the failure popping up. I will also be tweaking the experiment's `run.sh` to wait for the ASG to self-heal so that if an error pops up, we can get an idea of how quickly it gets resolved.

### Results

3/3 of the runs had the first Terraform apply trial fail and the ASG self heal within 59-65 seconds, followed by successful Terraform applies in the remaining 9 trials. The instance profile age at time of launch between trial 1 and trial 2 are also very tight across all three runs (and in the case of run 2 with account `347179352735`, younger in the successful trial 2):

| account | trial 1 profile age | trial 1 result | trial 2 profile age | trial 2 result |
|---|---|---|---|---|
| `399855128207` | 16.43s | FAILED | 17.52s | ok |
| `347179352735` | 18.84s | FAILED | 18.73s | ok |
| `994116601419` | 18.23s | FAILED | 20.61s | ok |

The range of time between the ASG being created and the first failed EC2 launch is 2.38 to 4.72 seconds (in line with successful launches).

This seems to show that the freshness of an account has a role in the first apply failing, but its exact cause is not clear from the ASG activity failure messages alone:

> "Launching a new EC2 instance.  Status Reason: Authentication Failure. Launching EC2 instance failed."

Interestingly, you can see from CloudTrail that when the first `CreateAutoScalingGroup` call is made for the `aws_autoscaling_group.main` resource in the module, `autoscaling.amazonaws.com` calls `CreateServiceLinkedRole` to create the `AWSServiceRoleForAutoScaling` role.

At `23:29:24.426`, you can see the first ASG launch failure that causes the first Terraform apply failure in the [saved ASG activities log](./experiment-2/results/20260907T232811Z/trial-01/activities.json).

Before reading the following CloudTrail logs that lead up to the first failure, make note that: 
1. `eventTime` in CloudTrail registers when a call was completed, so that's why the `CreateServiceLinkedRole` and calls up to our first `CreateAutoScalingGroup` look like they happened before it even though they were triggered by that call.
2. The ASG launch failure is not reflected within CloudTrail, and we only know about it from calling `DescribeScalingActivities` and saving the results to the [ASG activities log](./experiment-2/results/20260907T232811Z/trial-01/activities.json).
3. The `RunInstances` call is a [dry-run permissions check against the caller's role](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-launch-template-permissions.html#:~:text=we%20issue%20an%20Amazon%20EC2). We can see that it succeeded by looking at the error message in CloudTrail: "Request would have succeeded, but DryRun flag is set." The actual launches [run under the service-linked role's permissions](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-launch-template-permissions.html#:~:text=After%20the%20initial%20verification%20and%20request%20are%20complete).

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

The most interesting part of the log is that this shows the `AWSServiceRoleForAutoScaling` SLR is not pre-existing in the account, but instead created as part of the first call to `CreateAutoScalingGroup`. We can also confirm from AWS documentation that they are creating the SLR automatically for us [from their documention](https://docs.aws.amazon.com/autoscaling/ec2/userguide/autoscaling-service-linked-role.html#create-service-linked-role):

> "Amazon EC2 Auto Scaling creates the AWSServiceRoleForAutoScaling service-linked role for you the first time that you create an Auto Scaling group, unless you manually create a custom suffix service-linked role and specify it when creating the group."

You can then see in CloudTrail that the next time the ASG attempts a launch, it succeeds (at `23:30:29.276`) and uses the SLR it previously created:

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

The lack of a successful `AssumeRole` call before the failure in the first table seems to imply that the Terraform apply error is related to the timing of the SLR creation, which leads us to a third experiment.

## Experiment 3

### Setup

Previously, we show that the freshness of an account does play a factor in the failed ASG launch and thus failed Terraform apply. It's not clear from experiment 2 whether the issue is caused by the `AWSServiceRoleForAutoScaling` SLR not existing and needing to propagate or if it's simply a proxy for some once-per-account AWS backend setup that needs to occur before using Auto Scaling for the first time. We're going to run a quick experiment here of creating the missing SLR on a new account, waiting 300 seconds (~4 minutes past the average self-heal time from the results in experiment 2), and then applying the Terraform module to attempt to isolate the cause.

### Results

The apply succeeded on the account's first-ever ASG launch. You can confirm this in the [saved ASG activities log](./experiment-3/results/20260909T192116Z/trial-01/activities.json) for the run.

The age of the `AWSServiceRoleForAutoScaling` SLR at time of the first ASG launch was 5.5 minutes. The module's instance profile age was 18.76 seconds, and the time between the ASG being created and the first EC2 launch was 4.63 seconds. All of these measurements are in line with all previous failed and successful trials in experiment 1 and 2, indicating that nothing exceptional happened this run except for the SLR being pre-created and waiting on its propagation. We can also see that there is a successful `AssumeRole` call before the `CreateAutoScalingGroup` call, which never happened in the failing trials of experiment 2.

We can show the full timeline in CloudTrail of creating the `CreateServiceLinkedRole` through to the successful launch:

| time | invokedBy | event | identity |
|---|---|---|---|
| `19:21:21.000` | - | `CreateServiceLinkedRole` | `OrganizationAccountAccessRole/botocore-session-1788981676` |
| `19:21:21.000` | - | `GetRole` | `OrganizationAccountAccessRole/botocore-session-1788981676` |
| `19:26:23.000` | - | `GetRole` | `OrganizationAccountAccessRole/botocore-session-1788981676` |
| `19:26:32.000` | - | `DescribeImages` | `OrganizationAccountAccessRole/aws-go-sdk-1788981990867826000` |
| `19:26:32.000` | - | `DescribeRouteTables` | `OrganizationAccountAccessRole/aws-go-sdk-1788981990867826000` |
| `19:26:32.000` | - | `DescribeVpcAttribute` | `OrganizationAccountAccessRole/aws-go-sdk-1788981990867826000` |
| `19:26:32.000` | - | `DescribeVpcs` | `OrganizationAccountAccessRole/aws-go-sdk-1788981990867826000` |
| `19:26:32.000` | - | `GetCallerIdentity` | `OrganizationAccountAccessRole/aws-go-sdk-1788981990867826000` |
| `19:26:34.000` | - | `AssumeRole` | `AssumedRole` |
| `19:26:34.000` | - | `CreateInstanceProfile` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `CreatePolicy` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `CreateRole` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `GetCallerIdentity` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `GetPolicy` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `GetPolicyVersion` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `GetRole` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `ListAttachedRolePolicies` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:34.000` | - | `ListRolePolicies` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `AddRoleToInstanceProfile` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `AttachRolePolicy` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `CreateSecurityGroup` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `DescribeSecurityGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `DescribeSecurityGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `DescribeSecurityGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `GetInstanceProfile` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:35.000` | - | `ListAttachedRolePolicies` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:36.000` | - | `DescribeSecurityGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:36.000` | - | `RevokeSecurityGroupEgress` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:36.000` | - | `RevokeSecurityGroupEgress` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:37.000` | - | `AuthorizeSecurityGroupEgress` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:37.000` | - | `AuthorizeSecurityGroupIngress` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:37.000` | - | `DescribeSecurityGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:38.000` | - | `CreateNetworkInterface` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:38.000` | - | `DescribeNetworkInterfaces` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:38.000` | - | `ModifyNetworkInterfaceAttribute` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:39.000` | - | `DescribeNetworkInterfaces` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:40.000` | - | `GetInstanceProfile` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:40.000` | - | `GetInstanceProfile` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:40.000` | - | `GetInstanceProfile` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:40.000` | - | `GetInstanceProfile` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:40.000` | - | `GetRole` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:41.000` | - | `CreateLaunchTemplate` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:46.000` | - | `DescribeLaunchTemplateVersions` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:46.000` | - | `DescribeLaunchTemplates` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:46.000` | - | `DescribeLaunchTemplates` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:46.000` | - | `DescribeLaunchTemplates` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:46.000` | - | `DescribeLaunchTemplates` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:47.000` | autoscaling.amazonaws.com | `AssumeRole` | `AWSService` |
| `19:26:47.000` | autoscaling.amazonaws.com | `AssumeRole` | `AWSService` |
| `19:26:47.000` | autoscaling.amazonaws.com | `DescribeAvailabilityZones` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `19:26:47.000` | autoscaling.amazonaws.com | `DescribeLaunchTemplateVersions` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `19:26:47.000` | autoscaling.amazonaws.com | `DescribeSubnets` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `19:26:47.000` | autoscaling.amazonaws.com | `GetSecurityGroupsForVpc` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `19:26:48.000` | - | `CreateAutoScalingGroup` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:48.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:48.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:48.000` | autoscaling.amazonaws.com | `DescribeInstanceTypes` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `19:26:48.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:48.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:48.000` | autoscaling.amazonaws.com | `DescribeVpcs` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `19:26:48.000` | autoscaling.amazonaws.com | `RunInstances` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:49.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:49.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:50.000` | autoscaling.amazonaws.com | `AssumeRole` | `AWSService` |
| `19:26:50.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:50.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:52.000` | autoscaling.amazonaws.com | `CreateFleet` | `AWSServiceRoleForAutoScaling/AutoScaling` |
| `19:26:52.000` | - | `DescribeAutoScalingGroups` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:52.000` | - | `DescribeScalingActivities` | `OrganizationAccountAccessRole/aws-go-sdk-1788981993320666000` |
| `19:26:52.000` | autoscaling.amazonaws.com | `RunInstances` | `AWSServiceRoleForAutoScaling/AutoScaling` |

At `19:26:52.757` the first launch through the ASG succeeds with no prior failures. In the first `CreateAutoScalingGroup` call, we can see that the Auto Scaling service successfully calls `AssumeRole` because you can see the `Describe*` calls alongside it are all using `AWSServiceRoleForAutoScaling/AutoScaling` as their identity. This matches what success looks like after the first failed trial per run in experiment 2.

This appears to rule out that the SLR is just a proxy for the mechanism and instead shifts it towards being the direct cause. This helps confirm that the reporter's fix of adding a `time_sleep` would not help avert this failure because `time_sleep` wouldn't affect the time between the Auto Scaling service automatically creating the SLR and using it. The maintainer likely wasn't able to reproduce the results because to recreate the results, you have to use an account that has never created an ASG in any way.

## Experiment 4

### Setup

We will test the maintainer's fix on 3 fresh new AWS accounts that don't have a pre-existing `AWSServiceRoleForAutoScaling` SLR. Now that we know why Terraform applies are failing in fresh accounts, we're going to use the maintainer's fix on the `asg-iam-propagation-race` branch [mentioned in this issue comment](https://github.com/RaJiska/terraform-aws-fck-nat/issues/85#issuecomment-5327877194) to validate the fix.

### Results

The fix works. On all 3 runs with fresh accounts, the Terraform applies within all 10 trials were successful. In all 3 runs, the ASG's first launch in trial 1 fails and recovers between 61.08 and 65.61 seconds, which aligns with the range of ASG self-heal times we saw in experiment 2.

We can look at the spread of Terraform apply durations to see the effect of waiting on the ASG to self heal in the trial 1 Terraform apply compared to the trial 2-10 applies (where the SLR already exists):

| account | trial 1 apply duration | trials 2-10 apply duration range | trials 2-10 apply duration mean | delta between first apply and trials 2-10 mean |
|---|---|---|---|---|
| `747228343889` | 100s | 32-34s | 32.7s | +67.3s |
| `310556628235` | 95s | 32-33s | 32.7s | +62.3s |
| `711318977523` | 96s | 32-33s | 32.9s | +63.1s |

At this point, across the 6 fresh accounts where we deployed the module without a preexisting SLR, before we applied the fix, 3/6 resulted in failed Terraform applies, and after we applied the fix, the remaining 3/6 fresh accounts had successful Terraform applies.


