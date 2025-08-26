#!/bin/bash

# 部署成功驗證腳本
# 確認 EKS + Karpenter v1.6.2 部署完全成功
# Author: jasontsai

set -e

echo "🔍 開始驗證 EKS + Karpenter 部署狀態"
echo "========================================"
echo ""

# 環境變數
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export KUBECONFIG=~/.kube/config

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 驗證結果追蹤
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# 測試函數
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="$3"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    echo -n "測試 $TOTAL_TESTS: $test_name... "
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 通過${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        return 0
    else
        echo -e "${RED}❌ 失敗${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

# 詳細檢查函數
detailed_check() {
    local check_name="$1"
    local check_command="$2"
    
    echo ""
    echo "🔍 詳細檢查: $check_name"
    echo "----------------------------------------"
    eval "$check_command"
}

echo "🔧 階段 1: AWS 基礎設施驗證"
echo "----------------------------------------"

# 1.1 AWS CLI 配置檢查
run_test "AWS CLI 配置" "aws sts get-caller-identity"

# 1.2 EKS 集群狀態
run_test "EKS 集群存在" "aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.status' --output text | grep -q 'ACTIVE'"

# 1.3 VPC 存在
run_test "VPC 資源存在" "aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text | grep -q 'vpc-'"

# 1.4 IAM 角色存在
run_test "EKS 集群角色存在" "aws iam get-role --role-name eks-lab-test-eks-cluster-role"
run_test "節點群組角色存在" "aws iam get-role --role-name eks-lab-test-eks-node-group-role"

echo ""
echo "🔧 階段 2: Kubernetes 連接驗證"
echo "----------------------------------------"

# 2.1 kubectl 配置
run_test "kubectl 配置正確" "kubectl cluster-info | grep -q 'ap-southeast-1.eks.amazonaws.com'"

# 2.2 節點狀態
run_test "EKS 節點就緒" "kubectl get nodes --no-headers | grep -q 'Ready'"

# 2.3 系統 Pods 運行
run_test "CoreDNS 運行" "kubectl get pods -n kube-system -l k8s-app=kube-dns | grep -q 'Running'"
run_test "Metrics Server 運行" "kubectl get pods -n kube-system -l k8s-app=metrics-server | grep -q 'Running'"

echo ""
echo "🔧 階段 3: Karpenter 安裝驗證"  
echo "----------------------------------------"

# 3.1 Karpenter CRDs
run_test "NodePool CRD 存在" "kubectl get crd nodepools.karpenter.sh"
run_test "EC2NodeClass CRD 存在" "kubectl get crd ec2nodeclasses.karpenter.k8s.aws"

# 3.2 Karpenter 部署
run_test "Karpenter Pod 運行" "kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter | grep -q 'Running'"

# 3.3 Karpenter 版本
run_test "Karpenter 版本 1.6.2" "kubectl get deployment karpenter -n kube-system -o jsonpath='{.metadata.labels.app\\.kubernetes\\.io/version}' | grep -q '1.6.2'"

# 3.4 Karpenter 資源配置
run_test "NodePool 配置存在" "kubectl get nodepool general-purpose"
run_test "EC2NodeClass 配置存在" "kubectl get ec2nodeclass default"

# 3.5 Karpenter IAM
run_test "Karpenter Controller 角色" "aws iam get-role --role-name KarpenterControllerRole-eks-lab-test-eks"
run_test "Karpenter Node 角色" "aws iam get-role --role-name KarpenterNodeRole-eks-lab-test-eks"

echo ""
echo "🔧 階段 4: AWS Load Balancer Controller 驗證"
echo "----------------------------------------"

# 4.1 AWS LBC 部署
run_test "AWS LBC Pod 運行" "kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller | grep -q 'Running'"

# 4.2 AWS LBC 副本數
run_test "AWS LBC 副本正確" "test \$(kubectl get deployment aws-load-balancer-controller -n kube-system -o jsonpath='{.status.readyReplicas}') -eq 2"

# 4.3 AWS LBC IAM
run_test "AWS LBC 角色存在" "aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole" 

echo ""
echo "🔧 階段 5: 網絡和標記驗證"
echo "----------------------------------------"

# 5.1 子網路標記
VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text)
run_test "私有子網路標記正確" "aws ec2 describe-subnets --region $AWS_REGION --filters 'Name=vpc-id,Values=$VPC_ID' 'Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME' --query 'Subnets' --output text | grep -q 'subnet-'"

# 5.2 安全群組標記  
run_test "安全群組標記正確" "aws ec2 describe-security-groups --region $AWS_REGION --filters 'Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME' --query 'SecurityGroups' --output text | grep -q 'sg-'"

echo ""
echo "🔧 階段 6: 功能測試"
echo "----------------------------------------"

# 6.1 創建測試 Pod
echo -n "測試 $(($TOTAL_TESTS + 1)): 創建測試 Pod... "
TOTAL_TESTS=$((TOTAL_TESTS + 1))

cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: validation-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: validation-test
  template:
    metadata:
      labels:
        app: validation-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
EOF

# 等待 Pod 就緒
if timeout 60 bash -c 'while [[ $(kubectl get pod -l app=validation-test -o jsonpath="{.items[*].status.phase}" 2>/dev/null) != "Running" ]]; do sleep 2; done'; then
    echo -e "${GREEN}✅ 通過${NC}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    
    # 清理測試 Pod
    kubectl delete deployment validation-test >/dev/null 2>&1
else
    echo -e "${RED}❌ 失敗${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

echo ""
echo "📊 詳細系統狀態"
echo "========================================"

# 詳細檢查 - 節點資訊
detailed_check "EKS 節點資訊" "kubectl get nodes -o wide"

# 詳細檢查 - Karpenter 狀態
detailed_check "Karpenter 狀態" "kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter -o wide"

# 詳細檢查 - NodePool 狀態
detailed_check "NodePool 狀態" "kubectl get nodepools -o wide"

# 詳細檢查 - AWS LBC 狀態
detailed_check "AWS Load Balancer Controller 狀態" "kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o wide"

# 詳細檢查 - Helm 部署
detailed_check "Helm 部署狀態" "helm list -A"

# 詳細檢查 - IAM 角色
detailed_check "IAM 角色摘要" "echo 'Cluster Role:'; aws iam get-role --role-name eks-lab-test-eks-cluster-role --query 'Role.Arn' --output text 2>/dev/null || echo 'Not found'; echo 'Karpenter Controller Role:'; aws iam get-role --role-name KarpenterControllerRole-eks-lab-test-eks --query 'Role.Arn' --output text 2>/dev/null || echo 'Not found'; echo 'AWS LBC Role:'; aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole --query 'Role.Arn' --output text 2>/dev/null || echo 'Not found'"

echo ""
echo "🔍 最新日誌檢查"
echo "========================================"

# Karpenter 日誌
echo "Karpenter 最新日誌:"
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=3 2>/dev/null || echo "無法獲取日誌"

echo ""
echo "AWS Load Balancer Controller 最新日誌:"
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=3 2>/dev/null || echo "無法獲取日誌"

echo ""
echo "📋 測試結果摘要"
echo "========================================"
echo "總測試數: $TOTAL_TESTS"
echo -e "通過測試: ${GREEN}$PASSED_TESTS${NC}"
echo -e "失敗測試: ${RED}$FAILED_TESTS${NC}"

if [ $FAILED_TESTS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}🎉 所有測試通過！部署驗證成功！${NC}"
    echo ""
    echo "✅ EKS 集群運行正常"
    echo "✅ Karpenter v1.6.2 部署成功"
    echo "✅ AWS Load Balancer Controller 運行正常"
    echo "✅ 所有必要的 IAM 角色已配置"
    echo "✅ 網絡和標記配置正確"
    echo "✅ Pod 調度功能正常"
    echo ""
    echo "🚀 系統已準備好投入使用！"
    
    exit 0
else
    echo ""
    echo -e "${RED}⚠️  部署驗證失敗！${NC}"
    echo "請檢查失敗的測試項目並修復相關問題"
    echo ""
    echo "常見修復方法:"
    echo "1. 重新執行安裝腳本: ./scripts/setup-karpenter-v162.sh"
    echo "2. 檢查 AWS 權限配置"
    echo "3. 驗證 kubeconfig 設置: export KUBECONFIG=~/.kube/config"
    echo "4. 查看詳細日誌進行故障排除"
    
    exit 1
fi