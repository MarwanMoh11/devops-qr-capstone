# Reads the CI deploy role created by infra/bootstrap (bootstrap must run first).
data "aws_iam_role" "gha_deploy" {
  name = "${var.project}-gha-deploy"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  # v21 input names (v20 used cluster_name, cluster_version, cluster_addons, ...).
  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # EKS defaults to EXTENDED support ($0.60/h instead of $0.10/h once standard
  # support ends). STANDARD auto-upgrades instead, which is fine for a demo.
  upgrade_policy = { support_type = "STANDARD" }

  # Access entries only (no aws-auth ConfigMap).
  authentication_mode = "API"

  # Public endpoint: GitHub-hosted runners and the laptop need it.
  # Private endpoint: nodes talk to the API server inside the VPC.
  endpoint_public_access  = true
  endpoint_private_access = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.public_subnets
  control_plane_subnet_ids = module.vpc.public_subnets

  # No control-plane logs and no KMS key: nothing billable left behind, and no
  # KMS key stuck in "pending deletion" after destroy. EKS still envelope-
  # encrypts secrets with an AWS-owned key by default.
  enabled_log_types           = []
  create_cloudwatch_log_group = false
  create_kms_key              = false
  encryption_config           = null

  # Pod Identity only, so no per-cluster IAM OIDC provider (IRSA) is needed.
  enable_irsa = false

  # Admin is an explicit, fixed principal. Creator-admin would make the plan
  # differ depending on who runs it (laptop vs CI plan role).
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    admin = {
      principal_arn = var.admin_principal_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }

    gha_deploy = {
      principal_arn = data.aws_iam_role.gha_deploy.arn
      policy_associations = {
        edit_qr_app = {
          policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["qr-app"]
          }
        }
      }
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min
      desired_size = var.node_desired
      max_size     = var.node_max

      subnet_ids = module.vpc.public_subnets

      # Nodes get only the module's node SG, which the module tags
      # kubernetes.io/cluster/<name>=owned (verified in v21 node_groups.tf).
      # The in-tree LB controller needs exactly ONE cluster-tagged SG per node;
      # attaching the cluster primary SG (also tagged) would make it two.
      attach_cluster_primary_security_group = false

      # IMDSv2 with hop limit 2 (module v21 default is 1). AWS's Container Insights
      # docs ask for hop limit 2 so the CloudWatch agent pods can reach IMDS from a
      # container network namespace; with 1 node metadata/metrics can go missing.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  addons = local.addons
}
