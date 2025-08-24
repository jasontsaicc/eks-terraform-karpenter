#!/bin/bash

# EKS Cluster 銷毀腳本
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

# 檢查資源
check_resources() {
    log_info "檢查現有資源..."
    terraform state list
}

# 銷毀確認
confirm_destroy() {
    log_warn "警告：此操作將銷毀所有 EKS 資源！"
    log_warn "這是不可逆的操作！"
    
    echo ""
    read -p "請輸入 'DESTROY' 來確認銷毀: " confirm
    
    if [ "$confirm" != "DESTROY" ]; then
        log_info "銷毀操作已取消"
        exit 0
    fi
}

# 執行銷毀
destroy_resources() {
    log_info "開始銷毀資源..."
    
    # 首先移除 Helm releases（避免 finalizers 問題）
    log_info "移除 Helm releases..."
    helm list -A | grep -v NAME | awk '{print $1 " " $2}' | while read name namespace; do
        log_info "刪除 Helm release: $name in namespace: $namespace"
        helm delete $name -n $namespace || true
    done
    
    # 等待資源清理
    sleep 10
    
    # 執行 Terraform destroy
    terraform destroy -var-file=environments/test/terraform.tfvars -auto-approve
}

# 清理本地狀態
cleanup_local() {
    log_info "清理本地狀態檔案..."
    
    read -p "是否要清理本地 Terraform 狀態檔案？ (yes/no): " clean_state
    
    if [ "$clean_state" == "yes" ]; then
        rm -rf .terraform
        rm -f .terraform.lock.hcl
        rm -f terraform.tfstate*
        log_info "本地狀態已清理"
    fi
}

# 主流程
main() {
    log_info "開始 EKS 集群銷毀流程"
    
    check_resources
    confirm_destroy
    destroy_resources
    cleanup_local
    
    log_info "銷毀流程完成！"
}

# 執行主流程
main