# fck-nat as released, with no fix applied. Identical to experiment-1's stack; only the account's condition
# differs, which is the point — same code, same region, same harness, one variable changed.
#
# Within one apply the module creates:
#   aws_iam_role.main -> aws_iam_instance_profile.main -> aws_launch_template.main -> aws_autoscaling_group.main[0]
#
# In this test the account has never had an Auto Scaling group, so trial 1's CreateAutoScalingGroup also
# causes AWSServiceRoleForAutoScaling to be created, and the launch fires seconds later against a role
# that has only just come into existence. Trials 2..N run against that same role as it ages.
#
# Deliberately does NOT set update_route_tables or eip_allocation_ids: this exercises the IAM -> ASG
# interaction only, and routing nothing keeps each trial cheap and side-effect free.
module "fck_nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "1.6.1" # latest release; contains neither proposed fix

  name      = var.trial_name
  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  instance_type = "t4g.nano"
}
