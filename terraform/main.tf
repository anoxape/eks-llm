provider "aws" {
  region = var.region
}

locals {
  merged_tags = merge(var.tags, {
    project = var.name
  })
}
