# Main Terraform Configuration for EKS Cluster

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
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  backend "s3" {
    bucket         = "eks-lab-terraform-state-7035226a"
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

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

locals {
  cluster_name = "${var.project_name}-${var.environment}-eks"
  
  # Node Groups 配置
  node_groups = {
    general = {
      desired_size   = var.node_group_desired_size
      min_size       = var.node_group_min_size
      max_size       = var.node_group_max_size
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type
      labels = {
        role = "general"
        environment = var.environment
      }
      taints = []
      tags = {
        NodeGroup = "general"
      }
    }
    
    # Spot 實例池（成本優化）
    spot = {
      desired_size   = var.enable_spot_instances ? 1 : 0
      min_size       = 0
      max_size       = 3
      instance_types = ["t3.small", "t3a.small"]
      capacity_type  = "SPOT"
      labels = {
        role = "spot"
        workload = "batch"
      }
      taints = var.enable_spot_instances ? [
        {
          key    = "spot"
          value  = "true"
          effect = "NoSchedule"
        }
      ] : []
      tags = {
        NodeGroup = "spot"
      }
    }
  }
}

# VPC Module
module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr          = var.vpc_cidr
  azs               = var.azs
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  cluster_name      = local.cluster_name
  enable_flow_logs  = false # 測試環境關閉以節省成本
  tags              = var.tags
}

# IAM Module
module "iam" {
  source = "./modules/iam"

  cluster_name                        = local.cluster_name
  enable_irsa                         = var.enable_irsa
  cluster_oidc_issuer_url            = module.eks.cluster_oidc_issuer_url
  enable_karpenter                    = false # 初始部署先關閉
  enable_aws_load_balancer_controller = true
  enable_ebs_csi_driver              = var.enable_ebs_csi_driver
  tags                               = var.tags
}

# EKS Module
module "eks" {
  source = "./modules/eks"

  project_name                         = var.project_name
  environment                          = var.environment
  region                               = var.region
  vpc_id                               = module.vpc.vpc_id
  public_subnet_ids                    = module.vpc.public_subnet_ids
  private_subnet_ids                   = module.vpc.private_subnet_ids
  cluster_version                      = var.cluster_version
  cluster_endpoint_private_access      = var.cluster_endpoint_private_access
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  enable_cluster_encryption            = var.enable_cluster_encryption
  kms_key_arn                         = var.kms_key_arn
  cluster_iam_role_arn                = module.iam.cluster_iam_role_arn
  node_group_iam_role_arn             = module.iam.node_group_iam_role_arn
  node_groups                         = local.node_groups
  node_disk_size                      = var.node_disk_size
  enable_irsa                         = var.enable_irsa
  enable_ebs_csi_driver               = var.enable_ebs_csi_driver
  ebs_csi_driver_role_arn             = module.iam.ebs_csi_driver_role_arn
  tags                                = var.tags

  depends_on = [
    module.vpc,
    module.iam
  ]
}

# AWS Load Balancer Controller
resource "helm_release" "aws_load_balancer_controller" {
  count = var.enable_irsa ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.6.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.iam.aws_load_balancer_controller_role_arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [
    module.eks
  ]
}

# Metrics Server (用於 HPA)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.11.0"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [
    module.eks
  ]
}

# Cluster Autoscaler
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.29.3"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.region
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.iam.node_group_iam_role_arn
  }

  depends_on = [
    module.eks
  ]
}