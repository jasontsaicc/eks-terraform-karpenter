#!/bin/bash

# 自動化部署腳本 - 一鍵重建整個環境
# 從零開始部署 EKS + Karpenter v1.6.2
# Author: jasontsai

set -e

echo "🚀 自動化 EKS + Karpenter 部署腳本"
echo "========================================"
echo ""

# 環境變數設定
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export PROJECT_DIR="/home/ubuntu/projects/aws_eks_terraform"

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'  
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日誌函數
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# 階段計時
STAGE_START_TIME=$(date +%s)

stage_timer() {
    local stage_name="$1"
    local current_time=$(date +%s)
    local elapsed=$((current_time - STAGE_START_TIME))
    log_info "$stage_name (用時: ${elapsed}s)"
    STAGE_START_TIME=$current_time
}

echo "🔍 部署前檢查"
echo "========================================"

# 檢查必要工具
log_info "檢查必要工具..."

for tool in aws terraform kubectl helm jq bc; do
    if ! command -v $tool >/dev/null 2>&1; then
        log_error "$tool 未安裝"
        exit 1
    fi
done

log_success "所有必要工具已安裝"

# 檢查 AWS 認證
log_info "檢查 AWS 認證..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS 認證失敗，請配置 AWS CLI"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_success "AWS 認證成功 (Account: $ACCOUNT_ID)"

# 檢查工作目錄
log_info "檢查工作目錄..."
cd $PROJECT_DIR || {
    log_error "無法進入項目目錄: $PROJECT_DIR"
    exit 1
}

log_success "工作目錄: $(pwd)"

echo ""
stage_timer "部署前檢查完成"

# 階段 1: Terraform 基礎設施部署
echo ""
echo "🏗️ 階段 1: 部署基礎設施"
echo "========================================"

log_info "初始化 Terraform..."
terraform init

log_info "驗證 Terraform 配置..."
terraform validate

log_info "規劃基礎設施變更..."
terraform plan -out=tfplan

log_info "部署基礎設施 (預計 15-20 分鐘)..."
terraform apply tfplan

log_success "基礎設施部署完成"
stage_timer "基礎設施部署階段"

# 階段 2: kubectl 配置
echo ""
echo "⚙️  階段 2: 配置 kubectl"
echo "========================================"

log_info "更新 kubeconfig..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# 處理 K3s 衝突
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    log_warning "檢測到 K3s 集群，臨時禁用以避免衝突"
    sudo mv /etc/rancher/k3s/k3s.yaml /etc/rancher/k3s/k3s.yaml.bak 2>/dev/null || true
fi

export KUBECONFIG=~/.kube/config

log_info "驗證 EKS 連接..."
timeout 120 bash -c 'while ! kubectl get nodes >/dev/null 2>&1; do echo "等待 EKS 節點就緒..."; sleep 10; done'

NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
log_success "EKS 集群就緒，節點數量: $NODE_COUNT"
stage_timer "kubectl 配置階段"

# 階段 3: Karpenter 安裝
echo ""
echo "🎯 階段 3: 安裝 Karpenter v1.6.2"
echo "========================================"

log_info "執行 Karpenter 安裝腳本..."
if [ -f "./scripts/setup-karpenter-v162.sh" ]; then
    chmod +x ./scripts/setup-karpenter-v162.sh
    ./scripts/setup-karpenter-v162.sh
else
    log_error "Karpenter 安裝腳本不存在"
    exit 1
fi

log_success "Karpenter v1.6.2 安裝完成"
stage_timer "Karpenter 安裝階段"

# 階段 4: 驗證部署
echo ""
echo "🔍 階段 4: 驗證部署"
echo "========================================"

log_info "執行部署驗證..."
if [ -f "./scripts/validate-deployment.sh" ]; then
    chmod +x ./scripts/validate-deployment.sh
    if ./scripts/validate-deployment.sh; then
        log_success "所有驗證測試通過"
    else
        log_error "部署驗證失敗"
        exit 1
    fi
else
    log_warning "驗證腳本不存在，手動檢查..."
    
    # 基本檢查
    kubectl get nodes
    kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
    helm list -A
fi

stage_timer "部署驗證階段"

# 階段 5: 成本分析
echo ""
echo "💰 階段 5: 成本分析"
echo "========================================"

log_info "執行成本分析..."
if [ -f "./scripts/cost-monitor.sh" ]; then
    chmod +x ./scripts/cost-monitor.sh
    ./scripts/cost-monitor.sh
else
    log_warning "成本監控腳本不存在"
fi

stage_timer "成本分析階段"

# 恢復 K3s 配置
if [ -f /etc/rancher/k3s/k3s.yaml.bak ]; then
    log_info "恢復 K3s kubeconfig..."
    sudo mv /etc/rancher/k3s/k3s.yaml.bak /etc/rancher/k3s/k3s.yaml 2>/dev/null || true
fi

# 完成總結
echo ""
echo "🎉 部署完成！"
echo "========================================"

TOTAL_END_TIME=$(date +%s)
TOTAL_ELAPSED=$((TOTAL_END_TIME - STAGE_START_TIME + $(cat /tmp/deploy_start_time 2>/dev/null || echo 0)))

log_success "EKS 集群: $CLUSTER_NAME"
log_success "Karpenter 版本: v1.6.2"
log_success "AWS LBC 版本: v2.13.4"
log_success "總部署時間: ${TOTAL_ELAPSED}分鐘"

echo ""
echo "📋 使用說明:"
echo "----------------------------------------"
echo "• 使用 EKS 集群: export KUBECONFIG=~/.kube/config"
echo "• 使用 K3s 集群: unset KUBECONFIG"
echo "• 測試 Karpenter: kubectl apply -f simple-test.yaml"
echo "• 監控成本: ./scripts/cost-monitor.sh"
echo "• 驗證部署: ./scripts/validate-deployment.sh"
echo "• 清理資源: ./scripts/cleanup-complete.sh"

echo ""
echo "📊 重要資源:"
echo "----------------------------------------"
echo "• 集群端點: $(terraform output -raw cluster_endpoint 2>/dev/null || echo 'N/A')"
echo "• VPC ID: $(terraform output -raw vpc_id 2>/dev/null || echo 'N/A')" 
echo "• 區域: $AWS_REGION"

echo ""
echo "⚠️  注意事項:"
echo "• 每日預估成本: ~$5-8 USD"
echo "• 使用後請記得清理資源以節省費用"
echo "• 清理命令: ./scripts/cleanup-complete.sh"

echo ""
log_success "🚀 EKS + Karpenter 環境已準備就緒！"