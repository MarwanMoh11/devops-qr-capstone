data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Resolve AZ names from zone IDs: names are shuffled per account, IDs are not,
# and use1-az3 must be avoided for the control plane.
data "aws_availability_zones" "selected" {
  state = "available"

  filter {
    name   = "zone-id"
    values = var.az_ids
  }
}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition
  cluster_name = "${var.project}-eks"

  # 10.40.0.0/20 and 10.40.16.0/20 for the default CIDR.
  public_subnets = [for i in range(length(var.az_ids)) : cidrsubnet(var.vpc_cidr, 4, i)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr
  azs  = data.aws_availability_zones.selected.names

  # Public subnets only. A NAT gateway ($0.045/h + data) would cost more than
  # both nodes; nodes reach ECR/EKS/S3 through the internet gateway instead.
  public_subnets     = local.public_subnets
  enable_nat_gateway = false

  # Without NAT, nodes MUST get public IPs or they cannot pull images or join.
  map_public_ip_on_launch = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    # The in-tree service controller places internet-facing LBs in these.
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}
