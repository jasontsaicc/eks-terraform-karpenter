#!/bin/bash

# AWS EKS 資源清理腳本
# 安全地清理所有 EKS 相關資源

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 函數定義
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 顯示使用說明
show_help() {
    cat << EOF
使用方式: $0 [選項]

選項:
  --full              完整清理所有資源（預設）
  --k8s-only          僅清理 Kubernetes 資源
  --terraform-only    僅清理 Terraform 資源
  --dry-run           模擬執行，不實際刪除
  --force             跳過確認提示
  --help              顯示此幫助訊息

範例:
  $0 --full           # 完整清理所有資源
  $0 --k8s-only       # 僅清理 K8s 資源
  $0 --dry-run        # 模擬執行查看將刪除的資源
EOF
}

# 變數初始化
DRY_RUN=false
FORCE=false
CLEANUP_MODE="full"

# 解析參數
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --full)
                CLEANUP_MODE="full"
                shift
                ;;
            --k8s-only)
                CLEANUP_MODE="k8s"
                shift
                ;;
            --terraform-only)
                CLEANUP_MODE="terraform"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "無效選項: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 確認清理
confirm_cleanup() {
    if [ "$FORCE" = false ]; then
        echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}警告：此操作將刪除以下資源：${NC}"
        echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
        
        case $CLEANUP_MODE in
            full)
                echo "• 所有 Kubernetes 資源（Pods, Services, Deployments 等）"
                echo "• Karpenter 節點和配置"
                echo "• Helm Charts（Karpenter, AWS Load Balancer Controller 等）"
                echo "• EKS 集群和節點組"
                echo "• VPC 和網路資源"
                echo "• IAM 角色和策略"
                echo "• S3 儲存桶（如果有）"
                ;;
            k8s)
                echo "• 所有 Kubernetes 資源"
                echo "• Helm Charts"
                echo "• Karpenter 配置"
                ;;
            terraform)
                echo "• EKS 集群和節點組"
                echo "• VPC 和網路資源"
                echo "• IAM 角色和策略"
                ;;
        esac
        
        echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
        read -p "確定要繼續嗎？輸入 'yes' 確認: " confirm
        
        if [ "$confirm" != "yes" ]; then
            log_info "清理已取消"
            exit 0
        fi
    fi
}

# 執行命令（支援 dry-run）
execute_cmd() {
    local cmd="$1"
    local description="$2"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY-RUN]${NC} $description"
        echo "  命令: $cmd"
    else
        log_step "$description"
        eval "$cmd" || true
    fi
}

# 清理 Kubernetes 資源
cleanup_kubernetes() {
    log_info "開始清理 Kubernetes 資源..."
    
    # 檢查 kubectl 連接
    if ! kubectl cluster-info &> /dev/null; then
        log_warn "無法連接到 Kubernetes 集群，跳過 K8s 清理"
        return
    fi
    
    # 清理應用程式資源
    log_step "刪除應用程式部署..."
    execute_cmd "kubectl delete deployments --all -A --ignore-not-found" "刪除所有 Deployments"
    execute_cmd "kubectl delete statefulsets --all -A --ignore-not-found" "刪除所有 StatefulSets"
    execute_cmd "kubectl delete daemonsets --all -A --ignore-not-found" "刪除所有 DaemonSets"
    
    # 清理服務
    log_step "刪除服務..."
    execute_cmd "kubectl delete services --all -A --ignore-not-found" "刪除所有 Services"
    execute_cmd "kubectl delete ingress --all -A --ignore-not-found" "刪除所有 Ingress"
    
    # 清理 Karpenter 資源
    log_step "清理 Karpenter..."
    execute_cmd "kubectl delete nodepools --all --ignore-not-found" "刪除 NodePools"
    execute_cmd "kubectl delete nodeclaims --all --ignore-not-found" "刪除 NodeClaims"
    execute_cmd "kubectl delete ec2nodeclasses --all --ignore-not-found" "刪除 EC2NodeClasses"
    
    # 等待節點終止
    if [ "$DRY_RUN" = false ]; then
        log_step "等待 Karpenter 節點終止..."
        sleep 30
    fi
    
    # 卸載 Helm Charts
    log_step "卸載 Helm Charts..."
    execute_cmd "helm uninstall karpenter -n karpenter" "卸載 Karpenter"
    execute_cmd "helm uninstall aws-load-balancer-controller -n kube-system" "卸載 AWS Load Balancer Controller"
    execute_cmd "helm uninstall argocd -n argocd" "卸載 ArgoCD"
    execute_cmd "helm uninstall gitlab-runner -n gitlab-runner" "卸載 GitLab Runner"
    
    # 清理命名空間
    log_step "清理命名空間..."
    execute_cmd "kubectl delete namespace karpenter --ignore-not-found" "刪除 karpenter 命名空間"
    execute_cmd "kubectl delete namespace argocd --ignore-not-found" "刪除 argocd 命名空間"
    execute_cmd "kubectl delete namespace gitlab-runner --ignore-not-found" "刪除 gitlab-runner 命名空間"
    
    # 清理 PVC
    log_step "清理持久卷..."
    execute_cmd "kubectl delete pvc --all -A --ignore-not-found" "刪除所有 PVC"
    execute_cmd "kubectl delete pv --all --ignore-not-found" "刪除所有 PV"
}

# 清理 AWS 資源
cleanup_aws_resources() {
    log_info "清理 AWS 特定資源..."
    
    # 獲取集群名稱
    CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
    
    if [ -z "$CLUSTER_NAME" ]; then
        log_warn "無法獲取集群名稱，嘗試從 terraform.tfvars 讀取..."
        CLUSTER_NAME=$(grep cluster_name terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "eks-cluster")
    fi
    
    # 清理 EC2 實例（Karpenter 創建的）
    log_step "清理 Karpenter EC2 實例..."
    if [ "$DRY_RUN" = true ]; then
        aws ec2 describe-instances \
            --filters "Name=tag:karpenter.sh/cluster,Values=$CLUSTER_NAME" \
            --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' \
            --output table
    else
        INSTANCE_IDS=$(aws ec2 describe-instances \
            --filters "Name=tag:karpenter.sh/cluster,Values=$CLUSTER_NAME" \
            --query 'Reservations[].Instances[].InstanceId' \
            --output text)
        
        if [ ! -z "$INSTANCE_IDS" ]; then
            log_step "終止實例: $INSTANCE_IDS"
            aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
            
            log_step "等待實例終止..."
            aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
        fi
    fi
    
    # 清理 Launch Templates
    log_step "清理 Launch Templates..."
    LAUNCH_TEMPLATES=$(aws ec2 describe-launch-templates \
        --filters "Name=tag:karpenter.sh/cluster,Values=$CLUSTER_NAME" \
        --query 'LaunchTemplates[].LaunchTemplateId' \
        --output text)
    
    for lt in $LAUNCH_TEMPLATES; do
        execute_cmd "aws ec2 delete-launch-template --launch-template-id $lt" "刪除 Launch Template: $lt"
    done
    
    # 清理安全組（Karpenter 創建的）
    log_step "清理 Karpenter 安全組..."
    SECURITY_GROUPS=$(aws ec2 describe-security-groups \
        --filters "Name=tag:karpenter.sh/cluster,Values=$CLUSTER_NAME" \
        --query 'SecurityGroups[].GroupId' \
        --output text)
    
    for sg in $SECURITY_GROUPS; do
        execute_cmd "aws ec2 delete-security-group --group-id $sg" "刪除安全組: $sg"
    done
}

# 清理 Terraform 資源
cleanup_terraform() {
    log_info "清理 Terraform 資源..."
    
    if [ ! -f "main.tf" ]; then
        log_error "未找到 Terraform 配置文件"
        return
    fi
    
    # 初始化 Terraform
    log_step "初始化 Terraform..."
    if [ -f "backend-config.txt" ]; then
        terraform init -backend-config=backend-config.txt
    else
        terraform init
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_step "顯示將要銷毀的資源..."
        terraform plan -destroy
    else
        log_step "銷毀 Terraform 資源..."
        terraform destroy -auto-approve
    fi
}

# 清理本地文件
cleanup_local_files() {
    log_info "清理本地臨時文件..."
    
    execute_cmd "rm -f terraform.tfstate*" "刪除本地 tfstate 文件"
    execute_cmd "rm -f .terraform.lock.hcl" "刪除 Terraform lock 文件"
    execute_cmd "rm -rf .terraform/" "刪除 .terraform 目錄"
    execute_cmd "rm -f eks.tfplan tfplan" "刪除 Terraform 計劃文件"
    execute_cmd "rm -f kubeconfig_*" "刪除 kubeconfig 文件"
}

# 驗證清理結果
verify_cleanup() {
    log_info "驗證清理結果..."
    
    if [ "$DRY_RUN" = true ]; then
        return
    fi
    
    # 檢查 EC2 實例
    REMAINING_INSTANCES=$(aws ec2 describe-instances \
        --filters "Name=tag:karpenter.sh/cluster,Values=$CLUSTER_NAME" \
        "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text)
    
    if [ ! -z "$REMAINING_INSTANCES" ]; then
        log_warn "仍有運行中的實例: $REMAINING_INSTANCES"
    else
        log_info "✓ 所有 EC2 實例已清理"
    fi
    
    # 檢查 EKS 集群
    if aws eks describe-cluster --name $CLUSTER_NAME &> /dev/null; then
        log_warn "EKS 集群仍存在: $CLUSTER_NAME"
    else
        log_info "✓ EKS 集群已刪除"
    fi
    
    # 檢查 VPC
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=*$CLUSTER_NAME*" \
        --query 'Vpcs[0].VpcId' \
        --output text)
    
    if [ "$VPC_ID" != "None" ] && [ ! -z "$VPC_ID" ]; then
        log_warn "VPC 仍存在: $VPC_ID"
    else
        log_info "✓ VPC 已刪除"
    fi
}

# 生成清理報告
generate_cleanup_report() {
    local report_file="cleanup_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > $report_file << EOF
清理報告
========================================
時間: $(date)
模式: $CLEANUP_MODE
Dry Run: $DRY_RUN

執行的清理操作:
EOF
    
    if [[ "$CLEANUP_MODE" == "full" ]] || [[ "$CLEANUP_MODE" == "k8s" ]]; then
        echo "• Kubernetes 資源清理" >> $report_file
    fi
    
    if [[ "$CLEANUP_MODE" == "full" ]] || [[ "$CLEANUP_MODE" == "terraform" ]]; then
        echo "• Terraform 資源清理" >> $report_file
        echo "• AWS 資源清理" >> $report_file
    fi
    
    echo "" >> $report_file
    echo "清理完成！" >> $report_file
    
    log_info "清理報告已保存至: $report_file"
}

# 主函數
main() {
    parse_arguments "$@"
    
    log_info "開始清理流程 (模式: $CLEANUP_MODE, Dry Run: $DRY_RUN)"
    
    confirm_cleanup
    
    case $CLEANUP_MODE in
        full)
            cleanup_kubernetes
            cleanup_aws_resources
            cleanup_terraform
            cleanup_local_files
            ;;
        k8s)
            cleanup_kubernetes
            ;;
        terraform)
            cleanup_aws_resources
            cleanup_terraform
            cleanup_local_files
            ;;
    esac
    
    verify_cleanup
    generate_cleanup_report
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry Run 完成！未實際刪除任何資源。"
    else
        log_info "清理完成！所有指定的資源已被刪除。"
    fi
}

# 執行主函數
main "$@"