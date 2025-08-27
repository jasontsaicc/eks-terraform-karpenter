#!/bin/bash

# AWS EKS 統一部署腳本
# 支援多種部署模式：完整部署、分階段部署、僅 Karpenter

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 函數定義
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 顯示使用說明
show_help() {
    cat << EOF
使用方式: $0 [選項]

選項:
  --full              完整部署（預設）
  --phased            分階段部署
  --karpenter-only    僅部署 Karpenter
  --cleanup           清理所有資源
  --validate          僅驗證配置
  --monitor           啟動成本監控
  --help              顯示此幫助訊息

範例:
  $0 --full           # 完整部署所有組件
  $0 --phased         # 分階段互動式部署
  $0 --karpenter-only # 僅更新 Karpenter 配置
  $0 --cleanup        # 清理所有資源
EOF
}

# 檢查必要工具
check_prerequisites() {
    log_info "檢查必要工具..."
    
    local tools=("terraform" "kubectl" "helm" "aws" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            log_error "$tool 未安裝"
            exit 1
        fi
    done
    
    # 檢查 AWS 配置
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS 憑證未配置"
        exit 1
    fi
    
    log_info "所有必要工具已就緒"
}

# 初始化 Terraform
init_terraform() {
    log_info "初始化 Terraform..."
    
    if [ -f "backend-config.txt" ]; then
        terraform init -backend-config=backend-config.txt
    else
        log_warn "未找到 backend-config.txt，使用本地後端"
        terraform init
    fi
}

# 驗證配置
validate_config() {
    log_info "驗證 Terraform 配置..."
    terraform validate
    
    log_info "執行 Terraform 計劃..."
    terraform plan -out=eks.tfplan
    
    read -p "是否繼續部署？(y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "部署已取消"
        exit 0
    fi
}

# 部署 VPC 和網路
deploy_network() {
    log_info "部署 VPC 和網路基礎設施..."
    terraform apply -target=module.vpc -auto-approve
}

# 部署 EKS 集群
deploy_eks() {
    log_info "部署 EKS 集群..."
    terraform apply -target=module.eks -auto-approve
    
    # 更新 kubeconfig
    CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "eks-cluster")
    AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "ap-northeast-1")
    
    log_info "更新 kubeconfig..."
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
    
    # 等待節點就緒
    log_info "等待節點就緒..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

# 部署附加元件
deploy_addons() {
    log_info "部署 EKS 附加元件..."
    
    # AWS Load Balancer Controller
    log_info "安裝 AWS Load Balancer Controller..."
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName=$CLUSTER_NAME \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --wait
    
    # Metrics Server
    log_info "安裝 Metrics Server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
}

# 部署 Karpenter
deploy_karpenter() {
    log_info "部署 Karpenter..."
    
    # 獲取必要變數
    CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.endpoint" --output text)
    KARPENTER_IAM_ROLE_ARN=$(terraform output -raw karpenter_irsa_arn 2>/dev/null || echo "")
    KARPENTER_INSTANCE_PROFILE=$(terraform output -raw karpenter_instance_profile_name 2>/dev/null || echo "")
    
    # 安裝 Karpenter
    helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --version "1.0.8" \
        --namespace karpenter \
        --create-namespace \
        --set settings.clusterName=$CLUSTER_NAME \
        --set settings.clusterEndpoint=$CLUSTER_ENDPOINT \
        --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_IAM_ROLE_ARN \
        --set settings.defaultInstanceProfile=$KARPENTER_INSTANCE_PROFILE \
        --set settings.interruptionQueue=$CLUSTER_NAME \
        --wait
    
    # 部署 NodePool
    log_info "配置 Karpenter NodePool..."
    kubectl apply -f karpenter/provisioners.yaml
}

# 部署 GitOps
deploy_gitops() {
    log_info "部署 GitOps 工具..."
    
    read -p "選擇 GitOps 工具 (1=ArgoCD, 2=GitLab, 3=跳過): " choice
    
    case $choice in
        1)
            log_info "部署 ArgoCD..."
            kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
            kubectl apply -n argocd -f argocd/install.yaml
            ;;
        2)
            log_info "部署 GitLab Runner..."
            helm repo add gitlab https://charts.gitlab.io
            helm upgrade --install gitlab-runner gitlab/gitlab-runner \
                -f gitlab/runner-values.yaml \
                -n gitlab-runner --create-namespace
            ;;
        3)
            log_info "跳過 GitOps 部署"
            ;;
    esac
}

# 完整部署
full_deployment() {
    log_info "開始完整部署..."
    
    check_prerequisites
    init_terraform
    validate_config
    deploy_network
    deploy_eks
    deploy_addons
    deploy_karpenter
    deploy_gitops
    
    log_info "部署完成！"
    show_cluster_info
}

# 分階段部署
phased_deployment() {
    log_info "開始分階段部署..."
    
    check_prerequisites
    init_terraform
    
    while true; do
        echo -e "\n選擇要執行的階段:"
        echo "1) 驗證配置"
        echo "2) 部署網路 (VPC)"
        echo "3) 部署 EKS 集群"
        echo "4) 部署附加元件"
        echo "5) 部署 Karpenter"
        echo "6) 部署 GitOps"
        echo "7) 顯示集群資訊"
        echo "0) 退出"
        
        read -p "請選擇 (0-7): " choice
        
        case $choice in
            1) validate_config ;;
            2) deploy_network ;;
            3) deploy_eks ;;
            4) deploy_addons ;;
            5) deploy_karpenter ;;
            6) deploy_gitops ;;
            7) show_cluster_info ;;
            0) exit 0 ;;
            *) log_error "無效選項" ;;
        esac
    done
}

# 僅部署 Karpenter
karpenter_only() {
    log_info "僅部署 Karpenter..."
    
    check_prerequisites
    
    # 獲取集群名稱
    CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || read -p "輸入集群名稱: " CLUSTER_NAME)
    AWS_REGION=$(terraform output -raw region 2>/dev/null || echo "ap-northeast-1")
    
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
    deploy_karpenter
    
    log_info "Karpenter 部署完成！"
}

# 清理資源
cleanup_resources() {
    log_info "開始清理資源..."
    
    read -p "警告：這將刪除所有資源！確定要繼續嗎？(yes/no) " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "清理已取消"
        exit 0
    fi
    
    # 刪除 Kubernetes 資源
    log_info "刪除 Kubernetes 資源..."
    kubectl delete nodepools --all 2>/dev/null || true
    kubectl delete nodeclaims --all 2>/dev/null || true
    
    # 卸載 Helm charts
    log_info "卸載 Helm charts..."
    helm uninstall karpenter -n karpenter 2>/dev/null || true
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
    
    # 銷毀 Terraform 資源
    log_info "銷毀 Terraform 資源..."
    terraform destroy -auto-approve
    
    log_info "清理完成！"
}

# 顯示集群資訊
show_cluster_info() {
    echo -e "\n${GREEN}=== EKS 集群資訊 ===${NC}"
    echo "集群名稱: $CLUSTER_NAME"
    echo "區域: $AWS_REGION"
    echo "端點: $(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.endpoint' --output text)"
    
    echo -e "\n${GREEN}=== 節點狀態 ===${NC}"
    kubectl get nodes
    
    echo -e "\n${GREEN}=== 重要服務 ===${NC}"
    kubectl get svc -A | grep -E "(LoadBalancer|NodePort)"
    
    echo -e "\n${GREEN}=== Karpenter 狀態 ===${NC}"
    kubectl get nodepools 2>/dev/null || echo "Karpenter 未安裝"
    
    echo -e "\n${GREEN}=== 下一步 ===${NC}"
    echo "1. 部署應用程式："
    echo "   kubectl apply -f your-app.yaml"
    echo "2. 監控成本："
    echo "   ./scripts/monitor-costs.sh"
    echo "3. 查看 ArgoCD UI："
    echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

# 啟動成本監控
monitor_costs() {
    log_info "啟動成本監控..."
    
    if [ -f "scripts/monitor-costs.sh" ]; then
        ./scripts/monitor-costs.sh
    else
        log_error "monitor-costs.sh 不存在"
        exit 1
    fi
}

# 主程式
main() {
    case "${1:-}" in
        --full|"")
            full_deployment
            ;;
        --phased)
            phased_deployment
            ;;
        --karpenter-only)
            karpenter_only
            ;;
        --cleanup)
            cleanup_resources
            ;;
        --validate)
            check_prerequisites
            init_terraform
            validate_config
            ;;
        --monitor)
            monitor_costs
            ;;
        --help)
            show_help
            ;;
        *)
            log_error "無效選項: $1"
            show_help
            exit 1
            ;;
    esac
}

# 執行主程式
main "$@"