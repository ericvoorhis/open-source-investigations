variable "trial_name" {
  type        = string
  description = "Names every resource in the trial. Must be unique per trial — see the README's 'Why every trial needs a unique name'."
}

variable "vpc_id" {
  type        = string
  description = "Any VPC. Nothing here depends on its configuration."
}

variable "subnet_id" {
  type        = string
  description = "A public subnet in that VPC. The instance needs egress to reach the EC2 API at boot; it is never used to route anything."
}
