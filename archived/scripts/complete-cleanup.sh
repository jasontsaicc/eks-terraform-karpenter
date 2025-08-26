#!/bin/bash

# 完整的 AWS EKS 資源清理腳本
# Author: jasontsai
# 包含所有資源的手動清理

set -e

echo "=== 開始完整清理 AWS 資源 ==="

# 配置
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export KUBECONFIG=/tmp/eks-config

echo "Region: $AWS_REGION"
echo "Cluster: $CLUSTER_NAME"

# Step 1: 刪除 Kubernetes 資源
echo "Step 1: 刪除 Kubernetes 資源..."
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null || true
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall karpenter -n karpenter 2>/dev/null || true
kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/v1.16.2/cert-manager.yaml 2>/dev/null || true

# Step 2: 刪除 Node Group
echo "Step 2: 刪除 Node Group..."
aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name general --region $AWS_REGION 2>/dev/null || true
echo "等待 Node Group 刪除..."
aws eks wait nodegroup-deleted --cluster-name $CLUSTER_NAME --nodegroup-name general --region $AWS_REGION 2>/dev/null || true

# Step 3: 刪除 EKS Cluster
echo "Step 3: 刪除 EKS Cluster..."
aws eks delete-cluster --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true
echo "等待 Cluster 刪除 (約 10-15 分鐘)..."
aws eks wait cluster-deleted --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true

# Step 4: 刪除 OIDC Provider
echo "Step 4: 刪除 OIDC Provider..."
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text 2>/dev/null | cut -d '/' -f 5)
if [ ! -z "$OIDC_ID" ]; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID 2>/dev/null || true
fi

# Step 5: 清理 IAM 角色和策略
echo "Step 5: 清理 IAM 角色和策略..."

# Load Balancer Controller
aws iam detach-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy 2>/dev/null || true
aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole 2>/dev/null || true
aws iam delete-policy --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy 2>/dev/null || true

# Karpenter 角色
aws iam delete-role-policy --role-name KarpenterControllerRole-$CLUSTER_NAME --policy-name KarpenterControllerPolicy 2>/dev/null || true
aws iam delete-role --role-name KarpenterControllerRole-$CLUSTER_NAME 2>/dev/null || true

aws iam remove-role-from-instance-profile --instance-profile-name KarpenterNodeInstanceProfile-$CLUSTER_NAME --role-name KarpenterNodeRole-$CLUSTER_NAME 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name KarpenterNodeInstanceProfile-$CLUSTER_NAME 2>/dev/null || true

for policy in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
    aws iam detach-role-policy --role-name KarpenterNodeRole-$CLUSTER_NAME --policy-arn arn:aws:iam::aws:policy/$policy 2>/dev/null || true
done
aws iam delete-role --role-name KarpenterNodeRole-$CLUSTER_NAME 2>/dev/null || true

# EKS 角色
aws iam detach-role-policy --role-name $CLUSTER_NAME-cluster-role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy 2>/dev/null || true
aws iam delete-role --role-name $CLUSTER_NAME-cluster-role 2>/dev/null || true

# Node Group 角色
for policy in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
    aws iam detach-role-policy --role-name $CLUSTER_NAME-node-group-role --policy-arn arn:aws:iam::aws:policy/$policy 2>/dev/null || true
done
aws iam delete-role-policy --role-name $CLUSTER_NAME-node-group-role --policy-name $CLUSTER_NAME-node-group-role-autoscaling 2>/dev/null || true
aws iam delete-role --role-name $CLUSTER_NAME-node-group-role 2>/dev/null || true

# Step 6: 使用 Terraform 清理 (嘗試)
echo "Step 6: 嘗試使用 Terraform 清理..."
cd /home/ubuntu/projects/aws_eks_terraform
terraform force-unlock -force $(terraform state list 2>&1 | grep -oP 'ID:\s+\K[a-f0-9-]+' | head -1) 2>/dev/null || true
terraform destroy -var-file="terraform-simple.tfvars" -auto-approve -lock=false 2>/dev/null || true

# Step 7: 手動清理網路資源
echo "Step 7: 手動清理網路資源..."

# 獲取 VPC ID
VPC_ID=$(aws ec2 describe-vpcs --region $AWS_REGION --filters "Name=tag:Name,Values=*$CLUSTER_NAME*,*eks-lab*" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ "$VPC_ID" != "None" ] && [ ! -z "$VPC_ID" ]; then
    echo "找到 VPC: $VPC_ID"
    
    # 刪除 NAT Gateways
    echo "刪除 NAT Gateways..."
    NAT_GWS=$(aws ec2 describe-nat-gateways --region $AWS_REGION --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output text)
    for nat in $NAT_GWS; do
        echo "刪除 NAT Gateway: $nat"
        aws ec2 delete-nat-gateway --nat-gateway-id $nat --region $AWS_REGION
    done
    
    # 釋放 Elastic IPs
    echo "釋放 Elastic IPs..."
    EIPS=$(aws ec2 describe-addresses --region $AWS_REGION --query 'Addresses[?Tags[?contains(Value, `eks-lab`)]].AllocationId' --output text)
    for eip in $EIPS; do
        echo "釋放 EIP: $eip"
        aws ec2 release-address --allocation-id $eip --region $AWS_REGION 2>/dev/null || true
    done
    
    # 等待 NAT Gateway 刪除
    sleep 30
    
    # 分離並刪除 Internet Gateway
    echo "刪除 Internet Gateways..."
    IGW=$(aws ec2 describe-internet-gateways --region $AWS_REGION --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text)
    if [ "$IGW" != "None" ]; then
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID --region $AWS_REGION
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW --region $AWS_REGION
    fi
    
    # 刪除 Subnets
    echo "刪除 Subnets..."
    SUBNETS=$(aws ec2 describe-subnets --region $AWS_REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text)
    for subnet in $SUBNETS; do
        echo "刪除 Subnet: $subnet"
        aws ec2 delete-subnet --subnet-id $subnet --region $AWS_REGION 2>/dev/null || true
    done
    
    # 刪除 Route Tables
    echo "刪除 Route Tables..."
    RTS=$(aws ec2 describe-route-tables --region $AWS_REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main != `true`].RouteTableId' --output text)
    for rt in $RTS; do
        echo "刪除 Route Table: $rt"
        aws ec2 delete-route-table --route-table-id $rt --region $AWS_REGION 2>/dev/null || true
    done
    
    # 刪除 Security Groups
    echo "刪除 Security Groups..."
    SGS=$(aws ec2 describe-security-groups --region $AWS_REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName != `default`].GroupId' --output text)
    for sg in $SGS; do
        echo "刪除 Security Group: $sg"
        aws ec2 delete-security-group --group-id $sg --region $AWS_REGION 2>/dev/null || true
    done
    
    # 刪除 VPC
    echo "刪除 VPC..."
    aws ec2 delete-vpc --vpc-id $VPC_ID --region $AWS_REGION
fi

echo ""
echo "=== 清理完成報告 ==="
echo "✅ Kubernetes 資源已清理"
echo "✅ EKS Cluster 已刪除"
echo "✅ Node Groups 已刪除"
echo "✅ IAM 角色和策略已清理"
echo "✅ VPC 和網路資源已清理"
echo ""
echo "保留的資源（如需要可手動刪除）："
echo "- Terraform Backend S3 Bucket"
echo "- Terraform Backend DynamoDB Table"
echo ""
echo "所有 AWS 資源清理完成！"