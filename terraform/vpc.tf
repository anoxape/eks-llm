locals {
  az_bits = ceil(log(length(var.azs), 2))

  private_subnet = cidrsubnet(var.cidr, 1, 0)
  public_subnet = cidrsubnet(var.cidr, 1, 1)  # non-prod
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"

  name = var.name
  tags = local.merged_tags

  azs             = var.azs
  cidr            = var.cidr
  private_subnets = [for i, az in var.azs : cidrsubnet(local.private_subnet, local.az_bits, i)]
  public_subnets  = [for i, az in var.azs : cidrsubnet(local.public_subnet, local.az_bits, i)]

  enable_nat_gateway = true
  single_nat_gateway = true
}
