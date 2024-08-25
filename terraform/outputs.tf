output "region" {
  value = var.region
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "triton_s3_bucket_id" {
  value = module.triton_s3_bucket.s3_bucket_id
}

output "fluentbit_iam_role_arn" {
  value = module.fluentbit_iam_role.iam_role_arn
}
