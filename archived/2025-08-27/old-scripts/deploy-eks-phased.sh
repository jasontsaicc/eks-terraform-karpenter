#!/bin/bash

# EKS Phased Deployment Script
# Author: jasontsai
# This script handles circular dependencies by deploying in phases

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Set environment
export AWS_REGION=${AWS_REGION:-ap-southeast-1}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log_info "Deploying to Region: $AWS_REGION"
log_info "AWS Account: $AWS_ACCOUNT_ID"

# Phase 1: Backend check
log_step "Phase 1: Checking Terraform Backend..."

cd terraform-backend

if [ ! -f "terraform.tfstate" ]; then
    log_info "Initializing backend..."
    terraform init
    terraform apply -auto-approve
else
    log_info "Backend already exists"
fi

export BACKEND_BUCKET=$(terraform output -raw s3_bucket_name)
export BACKEND_REGION=$(terraform output -raw s3_bucket_region)
export BACKEND_DYNAMODB=$(terraform output -raw dynamodb_table_name)

cd ..

# Phase 2: Create temporary main.tf without circular dependencies
log_step "Phase 2: Preparing simplified configuration..."

# Backup original main.tf
cp main.tf main.tf.original

# Create simplified main.tf
cat > main.tf << 'EOF'
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
EOF

log_info "Configuration prepared"

# Phase 3: Initialize and deploy
log_step "Phase 3: Deploying EKS infrastructure..."

terraform init -reconfigure

log_info "Planning deployment..."
terraform plan -var-file="terraform-simple.tfvars" -out=eks.tfplan

log_info "Applying deployment (this will take 15-20 minutes)..."
terraform apply eks.tfplan

# Get outputs
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
export VPC_ID=$(terraform output -raw vpc_id)
export AWS_LB_ROLE_ARN=$(terraform output -raw aws_load_balancer_controller_role_arn)
export KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)

log_info "EKS cluster deployed successfully!"
log_info "Cluster Name: $CLUSTER_NAME"
log_info "Cluster Endpoint: $CLUSTER_ENDPOINT"

# Phase 4: Configure kubectl
log_step "Phase 4: Configuring kubectl..."

aws eks update-kubeconfig \
  --region $AWS_REGION \
  --name $CLUSTER_NAME \
  --alias $CLUSTER_NAME

kubectl get nodes

log_info "kubectl configured successfully!"

# Phase 5: Create OIDC Provider (if needed)
log_step "Phase 5: Setting up OIDC Provider..."

OIDC_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text)

OIDC_ID=$(echo $OIDC_URL | cut -d '/' -f 5)

# Check if OIDC provider exists
aws iam list-open-id-connect-providers | grep $OIDC_ID > /dev/null 2>&1

if [ $? -ne 0 ]; then
    log_info "Creating OIDC Provider..."
    
    # Get thumbprint
    THUMBPRINT=$(echo | openssl s_client -servername oidc.eks.$AWS_REGION.amazonaws.com \
      -showcerts -connect oidc.eks.$AWS_REGION.amazonaws.com:443 2>&- | \
      openssl x509 -fingerprint -noout | \
      sed 's/://g' | \
      awk -F= '{print tolower($2)}')
    
    aws iam create-open-id-connect-provider \
      --url $OIDC_URL \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list $THUMBPRINT \
      --region $AWS_REGION
else
    log_info "OIDC Provider already exists"
fi

log_info "Setup complete! You can now install Kubernetes addons."

echo ""
echo "========================================="
echo "Deployment Summary:"
echo "========================================="
echo "Cluster Name: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "VPC ID: $VPC_ID"
echo "Status: READY"
echo ""
echo "Next steps:"
echo "1. Install AWS Load Balancer Controller"
echo "2. Install Karpenter"
echo "3. Install ArgoCD"
echo "========================================="