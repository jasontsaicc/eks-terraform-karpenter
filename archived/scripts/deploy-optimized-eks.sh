#!/bin/bash

# Deploy Optimized EKS with Karpenter for Cost Optimization
# Author: jasontsai

set -e

echo "=== 部署成本優化的 EKS 集群 ==="
echo "架構: 最小系統節點 + Karpenter 動態應用節點"
echo ""

# Configuration
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Step 1: Initialize Terraform Backend
echo "Step 1: 初始化 Terraform Backend..."
cd /home/ubuntu/projects/aws_eks_terraform/terraform-backend
terraform init
terraform apply -auto-approve

# Step 2: Deploy VPC and EKS with minimal node group
echo "Step 2: 部署 VPC 和最小化的 EKS..."
cd /home/ubuntu/projects/aws_eks_terraform
terraform init
terraform apply -var-file="terraform-optimized.tfvars" -target=module.vpc -auto-approve
terraform apply -var-file="terraform-optimized.tfvars" -target=module.eks -auto-approve

# Step 3: Update kubeconfig
echo "Step 3: 更新 kubeconfig..."
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --kubeconfig /tmp/eks-config
export KUBECONFIG=/tmp/eks-config

# Step 4: Create OIDC Provider
echo "Step 4: 創建 OIDC Provider..."
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo $OIDC_URL | cut -d '/' -f 5)

aws iam create-open-id-connect-provider \
    --url $OIDC_URL \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
    2>/dev/null || echo "OIDC Provider already exists"

# Step 5: Install Karpenter
echo "Step 5: 安裝 Karpenter..."

# Create Karpenter namespace
kubectl create namespace karpenter 2>/dev/null || true

# Create IAM role for Karpenter
cat <<EOF > /tmp/karpenter-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:karpenter:karpenter",
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
    --role-name KarpenterControllerRole-${CLUSTER_NAME} \
    --assume-role-policy-document file:///tmp/karpenter-trust-policy.json \
    2>/dev/null || echo "Role already exists"

# Attach Karpenter policy
cat <<EOF > /tmp/karpenter-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": "*",
      "Action": [
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateTags",
        "ec2:DeleteLaunchTemplate",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "iam:AddRoleToInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:PassRole",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "pricing:GetProducts",
        "ssm:GetParameter"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
    --role-name KarpenterControllerRole-${CLUSTER_NAME} \
    --policy-name KarpenterControllerPolicy \
    --policy-document file:///tmp/karpenter-policy.json \
    2>/dev/null || echo "Policy already attached"

# Create Karpenter node instance profile
aws iam create-role \
    --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{"Effect": "Allow","Principal": {"Service": "ec2.amazonaws.com"},"Action": "sts:AssumeRole"}]}' \
    2>/dev/null || echo "Node role already exists"

# Attach policies to node role
for policy in \
    arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
    arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
    arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
    arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
do
    aws iam attach-role-policy --role-name KarpenterNodeRole-${CLUSTER_NAME} --policy-arn $policy 2>/dev/null || true
done

# Create instance profile
aws iam create-instance-profile --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} 2>/dev/null || true
aws iam add-role-to-instance-profile \
    --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
    --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    2>/dev/null || true

# Get cluster endpoint
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.endpoint" --output text)

# Install Karpenter using Helm
helm repo add karpenter https://charts.karpenter.sh 2>/dev/null || true
helm repo update

helm upgrade --install karpenter karpenter/karpenter \
    --namespace karpenter \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
    --set settings.clusterName=${CLUSTER_NAME} \
    --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
    --set settings.interruptionQueue=${CLUSTER_NAME} \
    --set controller.resources.requests.cpu=100m \
    --set controller.resources.requests.memory=100Mi \
    --set webhook.resources.requests.cpu=100m \
    --set webhook.resources.requests.memory=100Mi \
    --set tolerations[0].key=system-only \
    --set tolerations[0].value=true \
    --set tolerations[0].effect=NoSchedule \
    --set nodeSelector.role=system \
    --wait

echo ""
echo "=== 部署完成 ==="
echo "✅ VPC 和網路已配置"
echo "✅ EKS 集群已創建（最小系統節點）"
echo "✅ Karpenter 已安裝"
echo ""
echo "下一步: 配置 Karpenter Provisioner 和部署應用"