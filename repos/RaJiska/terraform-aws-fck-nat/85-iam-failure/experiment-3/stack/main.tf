# fck-nat as released, with no fix applied. Byte-identical to experiment-1's and experiment-2's stack apart from
# this comment — the module, the version, and the inputs are the same in all three, so any difference in
# outcome is attributable to the account's condition rather than to the Terraform.
#
# Within one apply the module creates:
#   aws_iam_role.main -> aws_iam_instance_profile.main -> aws_launch_template.main -> aws_autoscaling_group.main[0]
#
# In this test AWSServiceRoleForAutoScaling has been created explicitly by run.sh and left to age before
# any of this runs, so this is still the account's first-ever ASG but the service-linked role is already
# minutes old rather than seconds.
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
