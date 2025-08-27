#!/bin/bash

# AWS EKS 快速部署腳本
# 此腳本將自動部署完整的 EKS 環境

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 檢查必要工具
check_prerequisites() {
    log_step "檢查必要工具..."
    
    local missing_tools=()
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws-cli")
    fi
    
    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "缺少以下工具: ${missing_tools[*]}"
        log_error "請先安裝所有必要工具再重新運行"
        exit 1
    fi
    
    # 檢查 AWS 認證
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS 認證失敗，請執行 'aws configure' 設置認證"
        exit 1
    fi
    
    log_info "✓ 所有必要工具已就緒"
}

# 部署基礎設施
deploy_infrastructure() {
    log_step "部署 EKS 基礎設施..."
    
    # 使用簡化配置
    if [ ! -f terraform.tfvars ]; then
        cp terraform.tfvars.simple terraform.tfvars
        log_info "已創建默認 terraform.tfvars 文件"
    fi
    
    # 初始化 Terraform
    terraform init -backend-config=backend-config.hcl
    
    # 驗證配置
    terraform validate
    
    # 執行部署
    terraform apply -auto-approve
    
    log_info "✓ 基礎設施部署完成"
}

# 配置 kubectl
configure_kubectl() {
    log_step "配置 kubectl..."
    
    local cluster_name=$(terraform output -raw cluster_name)
    local region=$(terraform output -raw region)
    
    # 配置 kubectl
    aws eks update-kubeconfig \
        --region "$region" \
        --name "$cluster_name" \
        --kubeconfig ~/.kube/config-eks
    
    # 設置環境變數
    export KUBECONFIG=~/.kube/config-eks
    
    # 驗證連接
    kubectl cluster-info
    
    log_info "✓ kubectl 配置完成"
}

# 安裝 Karpenter
install_karpenter() {
    log_step "安裝 Karpenter..."
    
    if [ -f scripts/install-karpenter.sh ]; then
        chmod +x scripts/install-karpenter.sh
        ./scripts/install-karpenter.sh
    else
        log_warn "Karpenter 安裝腳本不存在，跳過 Karpenter 安裝"
    fi
    
    log_info "✓ Karpenter 安裝完成"
}

# 安裝其他服務
install_additional_services() {
    log_step "安裝其他必要服務..."
    
    export KUBECONFIG=~/.kube/config-eks
    
    # 安裝 Metrics Server
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    log_info "✓ 其他服務安裝完成"
}

# 驗證部署
verify_deployment() {
    log_step "驗證部署..."
    
    export KUBECONFIG=~/.kube/config-eks
    
    echo -e "\n📊 集群狀態報告:"
    echo "================================"
    
    # 檢查節點
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    echo "📍 節點數量: $node_count"
    
    # 檢查系統 Pod
    local system_pods=$(kubectl get pods -n kube-system --no-headers | wc -l)
    echo "🔧 系統 Pod 數量: $system_pods"
    
    # 檢查 Karpenter
    local karpenter_pods=$(kubectl get pods -n karpenter --no-headers 2>/dev/null | wc -l)
    echo "🚀 Karpenter Pod 數量: $karpenter_pods"
    
    # 檢查 Metrics Server
    local metrics_pods=$(kubectl get pods -n kube-system -l k8s-app=metrics-server --no-headers | wc -l)
    echo "📈 Metrics Server Pod 數量: $metrics_pods"
    
    echo "================================"
    
    log_info "✓ 部署驗證完成"
}

# 顯示後續步驟
show_next_steps() {
    echo ""
    echo "🎉 EKS 集群部署完成！"
    echo ""
    echo "📝 下一步操作："
    echo "1. 設置環境變數:"
    echo "   export KUBECONFIG=~/.kube/config-eks"
    echo ""
    echo "2. 驗證集群狀態:"
    echo "   kubectl get nodes"
    echo "   kubectl get pods -A"
    echo ""
    echo "3. 部署測試應用:"
    echo "   kubectl create deployment nginx --image=nginx"
    echo "   kubectl expose deployment nginx --port=80 --type=LoadBalancer"
    echo ""
    echo "4. 查看完整文檔:"
    echo "   cat EKS-DEPLOYMENT-GUIDE.md"
    echo ""
    echo "5. 清理資源 (如需要):"
    echo "   ./scripts/force-cleanup.sh"
    echo ""
}

# 主函數
main() {
    echo "🚀 開始 AWS EKS 完整部署..."
    echo ""
    
    check_prerequisites
    deploy_infrastructure
    configure_kubectl
    install_karpenter
    install_additional_services
    verify_deployment
    show_next_steps
    
    log_info "🎉 所有部署步驟已完成！"
}

# 處理中斷信號
trap 'log_error "部署被中斷"; exit 1' INT TERM

# 執行主函數
main "$@"