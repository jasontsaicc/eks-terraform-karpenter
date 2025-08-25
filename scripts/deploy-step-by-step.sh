#!/bin/bash

# Deploy EKS with Karpenter Step by Step
# Author: jasontsai

set -e

echo "=== 分步部署 EKS with Karpenter ==="
echo ""

export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cd /home/ubuntu/projects/aws_eks_terraform

# Step 1: Deploy VPC
echo "Step 1: 部署 VPC..."
terraform init -backend-config="bucket=eks-lab-terraform-state-58def540" \
               -backend-config="key=terraform.tfstate" \
               -backend-config="region=ap-southeast-1" \
               -backend-config="dynamodb_table=eks-lab-terraform-state-lock"

terraform apply -var-file="terraform-optimized.tfvars" -target=module.vpc -auto-approve

# Step 2: Deploy EKS
echo "Step 2: 部署 EKS..."
terraform apply -var-file="terraform-optimized.tfvars" -target=module.eks -auto-approve

# Step 3: Configure kubectl
echo "Step 3: 配置 kubectl..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --kubeconfig /tmp/eks-config
export KUBECONFIG=/tmp/eks-config

# Step 4: Verify cluster
echo "Step 4: 驗證集群..."
kubectl get nodes

echo ""
echo "基礎集群部署完成！"
echo "下一步執行: ./scripts/setup-karpenter.sh"