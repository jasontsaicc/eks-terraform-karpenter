#!/bin/bash

# EKS 集群驗證腳本
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

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

check_mark() {
    echo -e "${GREEN}✓${NC} $1"
}

cross_mark() {
    echo -e "${RED}✗${NC} $1"
}

# 檢查前置條件
check_prerequisites() {
    log_info "檢查前置條件..."
    
    local all_good=true
    
    # 檢查 kubectl
    if command -v kubectl &> /dev/null; then
        check_mark "kubectl 已安裝"
    else
        cross_mark "kubectl 未安裝"
        all_good=false
    fi
    
    # 檢查 AWS CLI
    if command -v aws &> /dev/null; then
        check_mark "AWS CLI 已安裝"
    else
        cross_mark "AWS CLI 未安裝"
        all_good=false
    fi
    
    # 檢查 Terraform
    if command -v terraform &> /dev/null; then
        check_mark "Terraform 已安裝"
    else
        cross_mark "Terraform 未安裝"
        all_good=false
    fi
    
    if [ "$all_good" = false ]; then
        log_error "請安裝缺少的工具後重新執行"
        exit 1
    fi
}

# 檢查 Terraform 狀態
check_terraform_state() {
    log_info "檢查 Terraform 狀態..."
    
    if [ ! -f "terraform.tfstate" ]; then
        log_error "找不到 terraform.tfstate 檔案"
        log_warn "請先執行 terraform apply"
        exit 1
    fi
    
    # 檢查是否有資源
    local resource_count=$(terraform state list | wc -l)
    if [ "$resource_count" -eq 0 ]; then
        log_error "Terraform 狀態中沒有資源"
        exit 1
    fi
    
    check_mark "Terraform 狀態正常 ($resource_count 個資源)"
}

# 檢查 AWS 資源
check_aws_resources() {
    log_info "檢查 AWS 資源..."
    
    # 獲取集群資訊
    local cluster_name=$(terraform output -raw cluster_name 2>/dev/null || echo "")
    local region=$(terraform output -raw region 2>/dev/null || echo "ap-east-1")
    
    if [ -z "$cluster_name" ]; then
        log_error "無法取得集群名稱"
        exit 1
    fi
    
    log_info "集群名稱: $cluster_name"
    log_info "區域: $region"
    
    # 檢查 EKS 集群狀態
    local cluster_status=$(aws eks describe-cluster --name "$cluster_name" --region "$region" --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$cluster_status" = "ACTIVE" ]; then
        check_mark "EKS 集群狀態: ACTIVE"
    else
        cross_mark "EKS 集群狀態: $cluster_status"
        return 1
    fi
    
    # 檢查節點群組
    local nodegroups=$(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$region" --query 'nodegroups' --output text 2>/dev/null || echo "")
    
    if [ -n "$nodegroups" ]; then
        check_mark "節點群組: $nodegroups"
        
        # 檢查每個節點群組的狀態
        for ng in $nodegroups; do
            local ng_status=$(aws eks describe-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng" --region "$region" --query 'nodegroup.status' --output text 2>/dev/null || echo "UNKNOWN")
            if [ "$ng_status" = "ACTIVE" ]; then
                check_mark "節點群組 $ng: ACTIVE"
            else
                cross_mark "節點群組 $ng: $ng_status"
            fi
        done
    else
        cross_mark "未找到節點群組"
    fi
}

# 檢查 Kubernetes 連接
check_kubernetes_connectivity() {
    log_info "檢查 Kubernetes 連接..."
    
    # 更新 kubeconfig
    local cluster_name=$(terraform output -raw cluster_name)
    local region=$(terraform output -raw region)
    
    aws eks --region "$region" update-kubeconfig --name "$cluster_name" &>/dev/null
    
    # 檢查 API server 連接
    if kubectl cluster-info &>/dev/null; then
        check_mark "Kubernetes API server 可達"
    else
        cross_mark "無法連接到 Kubernetes API server"
        return 1
    fi
    
    # 檢查節點狀態
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [ "$ready_nodes" -eq "$total_nodes" ] && [ "$ready_nodes" -gt 0 ]; then
        check_mark "所有節點就緒 ($ready_nodes/$total_nodes)"
    else
        cross_mark "節點狀態異常 ($ready_nodes/$total_nodes ready)"
    fi
    
    # 顯示節點詳細資訊
    echo ""
    log_info "節點詳細資訊:"
    kubectl get nodes -o wide
}

# 檢查系統 Pod
check_system_pods() {
    log_info "檢查系統 Pod 狀態..."
    
    # 檢查 kube-system namespace
    local running_pods=$(kubectl get pods -n kube-system --no-headers | grep -c "Running" || echo "0")
    local total_pods=$(kubectl get pods -n kube-system --no-headers | wc -l)
    
    if [ "$running_pods" -eq "$total_pods" ] && [ "$running_pods" -gt 0 ]; then
        check_mark "kube-system Pod 狀態正常 ($running_pods/$total_pods)"
    else
        cross_mark "kube-system Pod 狀態異常 ($running_pods/$total_pods running)"
    fi
    
    # 檢查 EKS Add-ons
    local addons=("vpc-cni" "kube-proxy" "coredns")
    for addon in "${addons[@]}"; do
        local addon_status=$(aws eks describe-addon --cluster-name "$(terraform output -raw cluster_name)" --addon-name "$addon" --region "$(terraform output -raw region)" --query 'addon.status' --output text 2>/dev/null || echo "NOT_FOUND")
        if [ "$addon_status" = "ACTIVE" ]; then
            check_mark "EKS Add-on $addon: ACTIVE"
        else
            cross_mark "EKS Add-on $addon: $addon_status"
        fi
    done
}

# 檢查服務和端點
check_services() {
    log_info "檢查核心服務..."
    
    # 檢查 kubernetes service
    if kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' &>/dev/null; then
        local cluster_ip=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')
        check_mark "Kubernetes service: $cluster_ip"
    else
        cross_mark "Kubernetes service 未就緒"
    fi
    
    # 檢查 DNS
    if kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' &>/dev/null; then
        local dns_ip=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
        check_mark "DNS service: $dns_ip"
    else
        cross_mark "DNS service 未就緒"
    fi
}

# 測試基本功能
test_basic_functionality() {
    log_info "測試基本功能..."
    
    # 建立測試 Pod
    kubectl run test-pod --image=nginx:alpine --rm -it --restart=Never -- /bin/sh -c "echo 'Hello from EKS!' && sleep 5" &>/dev/null
    
    if [ $? -eq 0 ]; then
        check_mark "Pod 建立和執行測試通過"
    else
        cross_mark "Pod 建立和執行測試失敗"
    fi
    
    # 測試 DNS 解析
    if kubectl run test-dns --image=alpine:latest --rm -it --restart=Never -- nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
        check_mark "DNS 解析測試通過"
    else
        cross_mark "DNS 解析測試失敗"
    fi
}

# 顯示摘要資訊
show_summary() {
    echo ""
    echo "================================================"
    log_info "集群摘要資訊"
    echo "================================================"
    
    # Terraform outputs
    terraform output 2>/dev/null | while read line; do
        echo "  $line"
    done
    
    echo ""
    log_info "建議的下一步操作："
    echo "  1. 安裝附加元件: ./scripts/setup-addons.sh"
    echo "  2. 部署測試應用程式"
    echo "  3. 設定監控和警報"
    echo "  4. 配置備份策略"
    
    echo ""
    log_success "EKS 集群驗證完成！"
}

# 主流程
main() {
    echo "================================================"
    log_info "EKS 集群驗證工具"
    echo "================================================"
    
    check_prerequisites
    check_terraform_state
    check_aws_resources
    check_kubernetes_connectivity
    check_system_pods
    check_services
    test_basic_functionality
    show_summary
}

# 執行主流程
main