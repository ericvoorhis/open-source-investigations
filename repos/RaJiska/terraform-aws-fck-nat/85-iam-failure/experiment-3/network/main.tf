# A throwaway VPC for the trials to launch into, applied ONCE before any trial and destroyed after.
#
# Deliberately not part of the trial itself. Terraform parallelises independent resources, and the ASG
# depends on both the IAM chain and the subnet — so it is created after whichever finishes last. IAM
# takes a few seconds; a VPC with a subnet and gateway takes longer. Building the network inside the
# trial would hand the instance profile that extra time to propagate and could mask the race entirely.
#
# Keeping it separate means every trial starts with the network already in place, so the ASG is gated
# only by the IAM chain — which is the condition under test.

resource "aws_vpc" "this" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "fck-nat-exp" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "fck-nat-exp" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.99.1.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "fck-nat-exp-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "fck-nat-exp-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
