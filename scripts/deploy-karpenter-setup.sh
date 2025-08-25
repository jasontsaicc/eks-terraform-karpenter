#!/bin/bash

# Deploy Complete Karpenter Setup
# Author: jasontsai

set -e

echo "=== 部署完整的 Karpenter 成本優化設置 ==="
echo ""

# Check if cluster exists
export KUBECONFIG=/tmp/eks-config
export CLUSTER_NAME=eks-lab-test-eks
export AWS_REGION=ap-southeast-1

if ! aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION &>/dev/null; then
    echo "EKS 集群不存在，開始部署..."
    /home/ubuntu/projects/aws_eks_terraform/scripts/deploy-optimized-eks.sh
    
    echo "等待集群就緒..."
    sleep 30
else
    echo "EKS 集群已存在，跳過集群創建"
fi

# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --kubeconfig /tmp/eks-config

# Step 1: Deploy Karpenter Provisioners
echo "Step 1: 部署 Karpenter Provisioners..."
kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/k8s-manifests/karpenter-provisioner.yaml

# Step 2: Deploy Time-based Scheduler
echo "Step 2: 部署時間排程器..."
kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/k8s-manifests/karpenter-scheduler.yaml

# Step 3: Install AWS Load Balancer Controller (needed for GitLab)
echo "Step 3: 安裝 AWS Load Balancer Controller..."

# Create IAM policy
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
curl -o /tmp/iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.2/docs/install/iam_policy.json

aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file:///tmp/iam_policy.json \
    2>/dev/null || echo "Policy already exists"

# Get OIDC provider
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)

# Create IAM role
cat <<EOF > /tmp/trust-policy.json
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
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    2>/dev/null || echo "Role already exists"

aws iam attach-role-policy \
    --role-name AmazonEKSLoadBalancerControllerRole \
    --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
    2>/dev/null || true

# Install using Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

kubectl create serviceaccount aws-load-balancer-controller -n kube-system 2>/dev/null || true

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=$CLUSTER_NAME \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKSLoadBalancerControllerRole" \
    --set nodeSelector.role=system \
    --set tolerations[0].key=system-only \
    --set tolerations[0].value=true \
    --set tolerations[0].effect=NoSchedule \
    --wait

# Step 4: Install Cert Manager
echo "Step 4: 安裝 Cert Manager..."
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.16.2/cert-manager.yaml

# Wait for cert-manager to be ready
sleep 30

# Patch cert-manager to use system nodes
kubectl patch deployment cert-manager -n cert-manager --patch '
spec:
  template:
    spec:
      nodeSelector:
        role: system
      tolerations:
      - key: system-only
        value: "true"
        effect: NoSchedule'

kubectl patch deployment cert-manager-webhook -n cert-manager --patch '
spec:
  template:
    spec:
      nodeSelector:
        role: system
      tolerations:
      - key: system-only
        value: "true"
        effect: NoSchedule'

kubectl patch deployment cert-manager-cainjector -n cert-manager --patch '
spec:
  template:
    spec:
      nodeSelector:
        role: system
      tolerations:
      - key: system-only
        value: "true"
        effect: NoSchedule'

# Step 5: Install ArgoCD
echo "Step 5: 安裝 ArgoCD..."
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Apply Karpenter optimizations for ArgoCD
sleep 10
kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/k8s-manifests/argocd-karpenter.yaml

# Step 6: Create Storage Class for GitLab
echo "Step 6: 創建 Storage Class..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: kubernetes.io/aws-ebs
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

# Step 7: Deploy GitLab (Optional - requires significant resources)
echo "Step 7: 準備 GitLab 部署（可選）..."
echo "GitLab 需要較多資源，可使用以下命令部署："
echo "kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/k8s-manifests/gitlab-karpenter.yaml"
echo ""

# Step 8: Verify deployment
echo "Step 8: 驗證部署..."
echo ""
echo "系統組件狀態:"
kubectl get pods -n kube-system | grep -E "aws-load-balancer|karpenter"
echo ""
echo "Karpenter Provisioners:"
kubectl get provisioners
echo ""
echo "當前節點:"
kubectl get nodes -L role,node-role

echo ""
echo "=== 部署完成 ==="
echo ""
echo "重要資訊:"
echo "1. Karpenter 已配置並準備就緒"
echo "2. 應用將自動觸發節點創建"
echo "3. 時間排程已設置（UTC 時間）:"
echo "   - 工作日 19:00 縮減"
echo "   - 工作日 08:00 擴展"
echo "   - 週五 20:00 週末關閉"
echo "   - 週一 08:00 週末啟動"
echo ""
echo "測試 Karpenter:"
echo "./scripts/test-karpenter-scaling.sh"
echo ""
echo "監控成本:"
echo "aws ce get-cost-and-usage --time-period Start=2024-01-01,End=2024-01-31 --granularity DAILY --metrics BLENDED_COST --dimensions Name=SERVICE,Values=AmazonEKS"