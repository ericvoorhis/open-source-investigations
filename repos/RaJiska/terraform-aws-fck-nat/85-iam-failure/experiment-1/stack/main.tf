# fck-nat as released, with no fix applied.
#
# Within one apply the module creates:
#   aws_iam_role.main -> aws_iam_instance_profile.main -> aws_launch_template.main -> aws_autoscaling_group.main[0]
#
# The hypothesis under test is #85's: that IAM instance profiles are eventually consistent, so the ASG's
# first launch attempt can fire before EC2 can resolve the profile, producing "Authentication Failure".
# Terraform's capacity wait treats any failed scaling activity as terminal, so the apply errors even
# though the ASG self-heals about a minute later.
#
# Every trial gets a unique var.name, so every trial presents EC2 with a role and instance profile
# created seconds earlier. If instance profile propagation is the cause, trials should fail at some rate.
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
