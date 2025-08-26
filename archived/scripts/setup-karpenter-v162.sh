#!/bin/bash

# Setup Karpenter v1.6.2 on EKS cluster - FIXED VERSION
# Author: jasontsai
# Version: 1.6.2

set -e

echo "=== 安裝 Karpenter v1.6.2 (修正版本) ==="
echo ""

export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# IMPORTANT: Use EKS kubeconfig, not K3s
echo "Step 0: 配置正確的 kubeconfig..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
export KUBECONFIG=~/.kube/config

# Verify we're connected to EKS, not K3s
CURRENT_NODES=$(kubectl get nodes --no-headers | wc -l)
FIRST_NODE=$(kubectl get nodes --no-headers -o custom-columns="NAME:.metadata.name" | head -1)
if [[ $FIRST_NODE =~ "ip-10-0" ]]; then
    echo "✅ 已連接到 EKS 集群"
else
    echo "❌ 錯誤: 仍連接到 K3s 集群，請檢查 kubeconfig"
    echo "提示: 如果是 K3s 環境，請先禁用 K3s kubeconfig"
    echo "sudo mv /etc/rancher/k3s/k3s.yaml /etc/rancher/k3s/k3s.yaml.bak"
    exit 1
fi

# Get cluster info
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.endpoint" --output text)
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text)
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.resourcesVpcConfig.vpcId" --output text)

echo "Cluster: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
echo "Endpoint: $CLUSTER_ENDPOINT"
echo "VPC ID: $VPC_ID"

# Step 1: Check if CRDs exist, if not install them
echo "Step 1: 檢查並安裝 Karpenter v1.6.2 CRDs..."
if ! kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1; then
    echo "安裝 CRDs..."
    kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.sh_nodepools.yaml
    kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
    kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml
else
    echo "CRDs 已存在，跳過安裝"
fi

# Step 2: Install/Upgrade Karpenter v1.6.2 with proper configuration
echo "Step 2: 安裝/升級 Karpenter v1.6.2..."

# Check if Karpenter is already installed
if helm list -n kube-system | grep -q karpenter; then
    echo "升級現有的 Karpenter..."
    helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
        --namespace kube-system \
        --version "1.6.2" \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
        --set "settings.clusterName=${CLUSTER_NAME}" \
        --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
        --set "settings.interruptionQueue=${CLUSTER_NAME}" \
        --set "settings.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
        --set "controller.resources.requests.cpu=1" \
        --set "controller.resources.requests.memory=1Gi" \
        --set "controller.resources.limits.cpu=2" \
        --set "controller.resources.limits.memory=2Gi" \
        --set "replicas=1" \
        --set "logLevel=info" \
        --wait
else
    echo "全新安裝 Karpenter..."
    helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --namespace kube-system \
        --version "1.6.2" \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
        --set "settings.clusterName=${CLUSTER_NAME}" \
        --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
        --set "settings.interruptionQueue=${CLUSTER_NAME}" \
        --set "settings.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
        --set "controller.resources.requests.cpu=1" \
        --set "controller.resources.requests.memory=1Gi" \
        --set "controller.resources.limits.cpu=2" \
        --set "controller.resources.limits.memory=2Gi" \
        --set "replicas=1" \
        --set "logLevel=info" \
        --wait
fi

# Step 3: Add AWS_REGION environment variable to prevent IMDS issues
echo "Step 3: 配置區域環境變數..."
kubectl patch deployment karpenter -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"controller","env":[{"name":"AWS_REGION","value":"'$AWS_REGION'"},{"name":"AWS_DEFAULT_REGION","value":"'$AWS_REGION'"}]}]}}}}'

# Step 4: Fix AWS Load Balancer Controller if needed
echo "Step 4: 檢查並修復 AWS Load Balancer Controller..."
if kubectl get deployment aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
    # Check if it's failing
    READY_REPLICAS=$(kubectl get deployment aws-load-balancer-controller -n kube-system -o jsonpath='{.status.readyReplicas}')
    if [[ "$READY_REPLICAS" == "0" ]] || [[ -z "$READY_REPLICAS" ]]; then
        echo "修復 AWS Load Balancer Controller..."
        
        # Add EKS chart repo if not exists
        helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
        helm repo update
        
        # Upgrade with proper VPC and region configuration
        helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName=$CLUSTER_NAME \
            --set serviceAccount.create=false \
            --set serviceAccount.name=aws-load-balancer-controller \
            --set region=$AWS_REGION \
            --set vpcId=$VPC_ID
    else
        echo "AWS Load Balancer Controller 已正常運行"
    fi
else
    echo "AWS Load Balancer Controller 不存在，跳過"
fi

# Step 5: Tag resources for Karpenter discovery
echo "Step 5: 標記資源供 Karpenter 使用..."

# Tag subnets
echo "標記私有子網路..."
for subnet in $(aws ec2 describe-subnets --region ${AWS_REGION} \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" \
    --query 'Subnets[].SubnetId' --output text); do
  aws ec2 create-tags --region ${AWS_REGION} \
    --resources $subnet \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME} 2>/dev/null || true
done

# Tag security groups
echo "標記安全群組..."
cluster_sg=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
if [[ ! -z "$cluster_sg" ]]; then
    aws ec2 create-tags --region ${AWS_REGION} \
        --resources $cluster_sg \
        --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME} 2>/dev/null || true
fi

# Step 6: Apply Karpenter NodePool and EC2NodeClass
echo "Step 6: 配置 Karpenter NodePool..."
if [ -f /home/ubuntu/projects/aws_eks_terraform/karpenter-nodepool-v162.yaml ]; then
    kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/karpenter-nodepool-v162.yaml
else
    echo "Warning: NodePool 配置文件未找到"
fi

# Step 7: Wait for Karpenter to be ready
echo "Step 7: 等待 Karpenter 準備就緒..."
kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n kube-system

echo ""
echo "=== Karpenter v1.6.2 安裝完成 ==="
echo ""
echo "檢查狀態:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
echo ""
kubectl get nodepools -A
echo ""
kubectl get ec2nodeclasses -A
echo ""
echo "✅ 安裝成功！"
echo ""
echo "使用方式:"
echo "1. 使用 EKS 集群: export KUBECONFIG=~/.kube/config"
echo "2. 使用 K3s 集群: unset KUBECONFIG (或重新登入)"
echo "3. 測試 Karpenter: kubectl apply -f simple-test.yaml"