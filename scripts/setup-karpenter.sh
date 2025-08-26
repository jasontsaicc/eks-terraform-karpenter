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
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:karpenter",
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

# Install CRDs first (v1.6.2 compatible)
echo "Installing Karpenter v1.6.2 CRDs..."
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.sh_nodepools.yaml
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml

# Create SQS Queue for interruption handling
echo "Creating SQS Queue..."
aws sqs create-queue --queue-name ${CLUSTER_NAME} --region ${AWS_REGION} 2>/dev/null || echo "Queue already exists"

# Add SQS and EKS permissions to IAM role
echo "Adding additional permissions to IAM role..."
cat <<'POLICY' > /tmp/additional-karpenter-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "sqs:GetQueueUrl",
        "sqs:GetQueueAttributes",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage"
      ],
      "Resource": "*"
    }
  ]
}
POLICY

aws iam put-role-policy \
    --role-name KarpenterControllerRole-${CLUSTER_NAME} \
    --policy-name KarpenterAdditionalPolicy \
    --policy-document file:///tmp/additional-karpenter-policy.json \
    2>/dev/null || echo "Additional policy already attached"

# Install Karpenter v1.6.2 with enhanced configuration
helm upgrade --install karpenter \
    oci://public.ecr.aws/karpenter/karpenter \
    --namespace karpenter \
    --create-namespace \
    --version "1.6.2" \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
    --set settings.clusterName=${CLUSTER_NAME} \
    --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
    --set settings.interruptionQueue=${CLUSTER_NAME} \
    --set controller.resources.requests.cpu=1 \
    --set controller.resources.requests.memory=1Gi \
    --set controller.resources.limits.cpu=2 \
    --set controller.resources.limits.memory=2Gi \
    --set replicas=2 \
    --set logLevel=info \
    --wait

# Step 5: Tag resources for Karpenter discovery
echo "Step 5: 標記資源供 Karpenter 使用..."

# Tag subnets
for subnet in $(aws ec2 describe-subnets --region ${AWS_REGION} \
    --filters "Name=vpc-id,Values=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)" \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' --output text); do
  aws ec2 create-tags --region ${AWS_REGION} \
    --resources $subnet \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
done

# Tag security group
cluster_sg=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 create-tags --region ${AWS_REGION} \
    --resources $cluster_sg \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}

# Step 6: Apply Karpenter NodePool and EC2NodeClass
echo "Step 6: 配置 Karpenter NodePool..."
if [ -f /home/ubuntu/projects/aws_eks_terraform/karpenter-nodepool.yaml ]; then
    kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/karpenter-nodepool.yaml
else
    echo "Warning: NodePool configuration file not found"
fi

echo ""
echo "=== Karpenter 安裝完成 ==="
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get nodepools -A
kubectl get ec2nodeclasses -A