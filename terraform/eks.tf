data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.23.0"

  cluster_name = var.name
  tags         = local.merged_tags

  cluster_version = "1.30"
  cluster_addons = {
    coredns = {}
    eks-pod-identity-agent = {}
    kube-proxy = {}
    vpc-cni = {}
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  kms_key_deletion_window_in_days = 7  # non-prod
  cloudwatch_log_group_retention_in_days = 1  # non-prod

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access = true  # non-prod

  authentication_mode = "API"

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_group_defaults = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }

    ebs_optimized = true

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_type           = "gp3"
          volume_size           = 100
          delete_on_termination = true
        }
      }
    }
  }

  # TODO: karpenter
  eks_managed_node_groups = {
    core = {
      instance_types = ["m6i.large"]

      desired_size = 2
      min_size     = 2
      max_size     = 2
    }

    gpu = {
      ami_type = "AL2_x86_64_GPU"
      instance_types = ["g4dn.xlarge"]

      desired_size = 4
      min_size     = 4
      max_size     = 4

      labels = {
        "nvidia.com/gpu.present" = "true"
      }

      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }
}
