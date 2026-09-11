# fck-nat from the maintainer's proposed fix branch, rather than the released v1.6.1 used in tests 1-3.
#
# The branch adds exactly two arguments to aws_autoscaling_group.main:
#
#   wait_for_capacity_timeout        = "5m"      (down from the provider default of 10m)
#   ignore_failed_scaling_activities = true
#
# ignore_failed_scaling_activities does not suppress the failure. Per the AWS provider, it stops a failed
# scaling activity from ABORTING the capacity wait — Terraform keeps waiting until desired capacity is
# reached or wait_for_capacity_timeout expires. So the ASG's first launch should still fail exactly as in
# test 2; what should change is that Terraform rides through it instead of erroring.
#
# The fix therefore depends on the ASG's own retry landing inside 5 minutes. Test 2 measured that recovery
# at 59.83s, 63.40s and 64.85s across three accounts, so it should — but that is the thing being checked.
#
# A passing run here looks like: apply_exit = 0, first_activity_status = Failed, activity_count = 2.
# The failure still happens; only Terraform's reaction to it differs.
#
# Everything else matches tests 1-3: same inputs, same instance type, no route tables or EIP.
module "fck_nat" {
  source = "git::https://github.com/RaJiska/terraform-aws-fck-nat.git?ref=asg-iam-propagation-race"

  name      = var.trial_name
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  instance_type = "t4g.nano"
}
