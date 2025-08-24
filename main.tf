terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }

  backend "s3" {
    bucket         = "eks-lab-terraform-state-58def540"
    key            = "eks/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "eks-lab-terraform-state-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}-eks"
}

# Phase 1: VPC only
module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr          = var.vpc_cidr
  azs               = var.azs
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  cluster_name      = local.cluster_name
  enable_flow_logs  = false
  tags              = var.tags
}

# Phase 2: IAM roles
module "iam" {
  source = "./modules/iam"

  cluster_name                        = local.cluster_name
  enable_irsa                         = var.enable_irsa
  cluster_oidc_issuer_url            = ""  # Will be updated after EKS creation
  enable_karpenter                    = false
  enable_aws_load_balancer_controller = true
  enable_ebs_csi_driver              = var.enable_ebs_csi_driver
  tags                               = var.tags
}

# Phase 3: EKS Cluster (simplified)
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = module.iam.cluster_iam_role_arn

  vpc_config {
    subnet_ids              = concat(module.vpc.public_subnet_ids, module.vpc.private_subnet_ids)
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = merge(
    var.tags,
    {
      Name = local.cluster_name
    }
  )

  depends_on = [
    module.iam,
    module.vpc
  ]
}

# Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "general"
  node_role_arn   = module.iam.node_group_iam_role_arn
  subnet_ids      = module.vpc.private_subnet_ids
  
  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type
  
  scaling_config {
    desired_size = var.node_group_desired_size
    max_size     = var.node_group_max_size
    min_size     = var.node_group_min_size
  }
  
  disk_size = var.node_disk_size
  
  tags = merge(
    var.tags,
    {
      Name = "${local.cluster_name}-general"
    }
  )
  
  depends_on = [
    aws_eks_cluster.main,
    module.iam
  ]
}

# Outputs
output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "aws_load_balancer_controller_role_arn" {
  value = module.iam.aws_load_balancer_controller_role_arn
}

output "node_group_iam_role_arn" {
  value = module.iam.node_group_iam_role_arn
}

output "karpenter_controller_role_arn" {
  value = module.iam.karpenter_controller_role_arn
}

output "region" {
  value = var.region
}
