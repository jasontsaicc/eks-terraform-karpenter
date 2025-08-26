#!/bin/bash

# Fixed Karpenter Test Script
# Author: jasontsai

set -e

echo "=== 測試 Karpenter 節點擴展（修復版）==="
echo ""

export KUBECONFIG=/tmp/eks-config
export CLUSTER_NAME=eks-lab-test-eks
export AWS_REGION=ap-southeast-1

# 清理舊資源
echo "清理舊測試資源..."
kubectl delete deployment test-app simple-test karpenter-test karpenter-scale-test 2>/dev/null || true
kubectl delete job test-runner-job 2>/dev/null || true

# 檢查 Karpenter 狀態
echo ""
echo "1. 檢查 Karpenter 狀態"
echo "========================="
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
echo ""
echo "NodePools:"
kubectl get nodepools -A
echo ""
echo "EC2NodeClasses:"
kubectl get ec2nodeclasses -A
echo ""

# 檢查當前節點
echo "2. 當前叢集節點"
echo "========================="
kubectl get nodes

# 檢查現有的 NodeClaims
echo ""
echo "3. 現有 NodeClaims"
echo "========================="
kubectl get nodeclaims -A

# 部署測試應用
echo ""
echo "4. 部署測試應用"
echo "========================="
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      # 使用 nodeSelector 確保調度到 Karpenter 管理的節點
      nodeSelector:
        nodepool: general-purpose
      containers:
      - name: nginx
        image: nginx:alpine
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
EOF

echo "等待 30 秒讓 Karpenter 處理..."
sleep 30

# 檢查 Pod 狀態
echo ""
echo "5. Pod 狀態"
echo "========================="
kubectl get pods -l app=karpenter-test -o wide

# 檢查 Karpenter 日誌
echo ""
echo "6. Karpenter 最近日誌"
echo "========================="
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=20 | grep -E "launching|provisioning|created|scheduled" || echo "無相關日誌"

# 檢查 NodeClaim 事件
echo ""
echo "7. NodeClaim 狀態和事件"
echo "========================="
for nc in $(kubectl get nodeclaims -o name); do
    echo "NodeClaim: $nc"
    kubectl describe $nc | grep -A 10 "Events:" || echo "無事件"
    echo "---"
done

# 診斷信息
echo ""
echo "8. 診斷信息"
echo "========================="
echo "檢查節點無法加入的可能原因："
echo ""

# 檢查子網路標記
echo "子網路標記："
aws ec2 describe-subnets --region $AWS_REGION \
    --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
    --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,Type:MapPublicIpOnLaunch}' \
    --output table

# 檢查安全群組標記
echo ""
echo "安全群組標記："
aws ec2 describe-security-groups --region $AWS_REGION \
    --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
    --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName}' \
    --output table

# 檢查節點實例配置檔
echo ""
echo "節點 IAM 角色："
aws iam get-role --role-name KarpenterNodeRole-$CLUSTER_NAME \
    --query 'Role.{RoleName:RoleName,Arn:Arn}' --output json 2>/dev/null || echo "角色不存在"

echo ""
echo "=== 測試總結 ==="
echo ""
echo "❓ Karpenter 可以創建 EC2 實例，但節點無法加入叢集"
echo ""
echo "可能的原因："
echo "1. ❌ 節點無法連接到 EKS API endpoint"
echo "   - 檢查 NAT Gateway 路由"
echo "   - 檢查安全群組規則"
echo ""
echo "2. ❌ 節點 IAM 角色權限不足"
echo "   - 需要 eks:DescribeCluster 權限"
echo "   - 需要能夠加入叢集的權限"
echo ""
echo "3. ❌ UserData 腳本問題"
echo "   - bootstrap.sh 可能需要額外參數"
echo "   - AMI 版本可能不相容"
echo ""
echo "建議解決方案："
echo "1. 手動 SSH 到 EC2 實例檢查 /var/log/cloud-init-output.log"
echo "2. 確認節點可以解析 EKS endpoint DNS"
echo "3. 檢查節點的 kubelet 日誌"
echo ""
echo "或者考慮使用 EC2 節點群組代替 Karpenter 進行測試"