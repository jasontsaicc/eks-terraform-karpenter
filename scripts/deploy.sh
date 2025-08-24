#!/bin/bash

# EKS Cluster 部署腳本
set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 函數定義
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 檢查必要工具
check_requirements() {
    log_info "檢查必要工具..."
    
    # 檢查 Terraform
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform 未安裝"
        exit 1
    fi
    
    # 檢查 AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI 未安裝"
        exit 1
    fi
    
    # 檢查 kubectl
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl 未安裝，將無法驗證集群"
    fi
    
    log_info "所有必要工具已就緒"
}

# 初始化 Terraform
init_terraform() {
    log_info "初始化 Terraform..."
    terraform init -upgrade
}

# 驗證配置
validate_config() {
    log_info "驗證 Terraform 配置..."
    terraform validate
    
    log_info "格式化 Terraform 檔案..."
    terraform fmt -recursive
}

# 規劃部署
plan_deployment() {
    log_info "規劃部署..."
    terraform plan -var-file=environments/test/terraform.tfvars -out=tfplan
}

# 執行部署
apply_deployment() {
    log_warn "即將部署 EKS 集群，這將產生 AWS 費用"
    read -p "確定要繼續嗎？ (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "部署已取消"
        exit 0
    fi
    
    log_info "開始部署..."
    terraform apply tfplan
    
    # 清理計劃檔案
    rm -f tfplan
}

# 配置 kubectl
configure_kubectl() {
    if command -v kubectl &> /dev/null; then
        log_info "配置 kubectl..."
        
        # 獲取集群名稱和區域
        CLUSTER_NAME=$(terraform output -raw cluster_name)
        REGION=$(terraform output -raw region)
        
        # 更新 kubeconfig
        aws eks --region $REGION update-kubeconfig --name $CLUSTER_NAME
        
        # 驗證連接
        log_info "驗證集群連接..."
        kubectl get nodes
        kubectl get pods -A
    else
        log_warn "kubectl 未安裝，跳過配置"
    fi
}

# 顯示輸出
show_outputs() {
    log_info "部署完成！以下是重要資訊："
    echo "================================================"
    terraform output
    echo "================================================"
}

# 主流程
main() {
    log_info "開始 EKS 集群部署流程"
    
    check_requirements
    init_terraform
    validate_config
    plan_deployment
    apply_deployment
    configure_kubectl
    show_outputs
    
    log_info "部署流程完成！"
    log_info "使用以下命令連接到集群："
    echo "$(terraform output -raw configure_kubectl)"
}

# 執行主流程
main