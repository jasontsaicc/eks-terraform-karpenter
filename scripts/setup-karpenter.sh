#!/bin/bash

# Setup Karpenter on existing EKS cluster
# Author: jasontsai

set -e

echo "=== 安裝 Karpenter ==="
echo ""

export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KUBECONFIG=/tmp/eks-config

# Get cluster info
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.endpoint" --output text)
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo $OIDC_URL | cut -d '/' -f 5)

echo "Cluster: $CLUSTER_NAME"
echo "Endpoint: $CLUSTER_ENDPOINT"
echo "OIDC ID: $OIDC_ID"

# Step 1: Create OIDC Provider
echo "Step 1: 創建 OIDC Provider..."
aws iam create-open-id-connect-provider \
    --url $OIDC_URL \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 \
    2>/dev/null || echo "OIDC Provider already exists"

# Step 2: Create Karpenter IAM Role
echo "Step 2: 創建 Karpenter IAM 角色..."

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

# Create Karpenter policy
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

# Step 3: Create Karpenter Node Role
echo "Step 3: 創建 Karpenter Node 角色..."

aws iam create-role \
    --role-name KarpenterNodeRole-${CLUSTER_NAME} \
    --assume-role-policy-document '{"Version": "2012-10-17","Statement": [{"Effect": "Allow","Principal": {"Service": "ec2.amazonaws.com"},"Action": "sts:AssumeRole"}]}' \
    2>/dev/null || echo "Node role already exists"

# Attach policies
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

# Step 4: Install Karpenter with Helm
echo "Step 4: 安裝 Karpenter..."

kubectl create namespace karpenter 2>/dev/null || true

helm repo add karpenter https://charts.karpenter.sh
helm repo update

helm upgrade --install karpenter karpenter/karpenter \
    --namespace karpenter \
    --version v0.35.0 \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
    --set settings.clusterName=${CLUSTER_NAME} \
    --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
    --set settings.interruptionQueue=${CLUSTER_NAME} \
    --set controller.resources.requests.cpu=100m \
    --set controller.resources.requests.memory=100Mi \
    --set webhook.resources.requests.cpu=100m \
    --set webhook.resources.requests.memory=100Mi \
    --wait

# Step 5: Apply Karpenter Provisioners
echo "Step 5: 配置 Karpenter Provisioners..."
kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/k8s-manifests/karpenter-provisioner.yaml

echo ""
echo "=== Karpenter 安裝完成 ==="
kubectl get pods -n karpenter
kubectl get provisioners