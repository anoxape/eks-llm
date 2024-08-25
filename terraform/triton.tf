module "triton_s3_bucket" {
  source = "terraform-aws-modules/s3-bucket/aws"
  version = "4.1.2"

  bucket_prefix = "${var.name}-triton-"
  tags          = local.merged_tags

  force_destroy = true  # non-prod
}

module "triton_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "1.4.0"

  name = "${var.name}-triton"
  tags = local.merged_tags

  associations = {
    triton = {
      cluster_name    = module.eks.cluster_name
      namespace       = "triton-server"
      service_account = "triton-server"
    }
  }

  additional_policy_arns = {
    triton = module.triton_iam_policy.arn
  }

  max_session_duration = 60 * 60 * 12  # hours # non-prod
}

module "triton_iam_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "5.44.0"

  name_prefix = "${var.name}-triton"
  tags        = local.merged_tags

  policy = data.aws_iam_policy_document.triton.json
}

data "aws_iam_policy_document" "triton" {
  statement {
    effect = "Allow"
    resources = [module.triton_s3_bucket.s3_bucket_arn]

    actions = [
      "s3:ListBucket",
    ]
  }

  statement {
    effect = "Allow"
    resources = ["${module.triton_s3_bucket.s3_bucket_arn}/*"]

    actions = [
      "s3:GetObject",
    ]
  }
}
