module "fluentbit_log_group" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/log-group"
  version = "5.5.0"

  name = "/aws/eks/${module.eks.cluster_name}/workload"
  tags = local.merged_tags

  retention_in_days = 1
}

# TODO: aws-for-fluent-bit pod-identity (https://github.com/aws/aws-for-fluent-bit/issues/784)
module "fluentbit_iam_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.44.0"

  role_name_prefix = "${var.name}-fluentbit"
  tags             = local.merged_tags

  oidc_providers = {
    eks = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "monitoring:aws-for-fluent-bit"
      ]
    }
  }

  role_policy_arns = {
    fluentbit_eks_policy = module.fluentbit_iam_policy.arn
  }
}

module "fluentbit_iam_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "5.44.0"

  name_prefix = "${var.name}-fluentbit"
  tags        = local.merged_tags

  policy = data.aws_iam_policy_document.fluentbit.json
}

data "aws_iam_policy_document" "fluentbit" {
  statement {
    effect = "Allow"
    resources = ["${module.fluentbit_log_group.cloudwatch_log_group_arn}:*"]

    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "logs:PutRetentionPolicy",
    ]
  }
}
