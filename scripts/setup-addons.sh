#!/bin/bash

# EKS 附加元件安裝腳本
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

# 獲取集群資訊
get_cluster_info() {
    export CLUSTER_NAME=$(terraform output -raw cluster_name)
    export REGION=$(terraform output -raw region)
    export OIDC_PROVIDER=$(terraform output -raw cluster_oidc_issuer_url | sed 's/https:\/\///')
    
    log_info "集群名稱: $CLUSTER_NAME"
    log_info "區域: $REGION"
}

# 安裝 ArgoCD
install_argocd() {
    log_info "安裝 ArgoCD..."
    
    # 建立 namespace
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # 安裝 ArgoCD
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    # 等待部署完成
    log_info "等待 ArgoCD 部署完成..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
    
    # 修改服務類型為 LoadBalancer（測試環境）
    kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
    
    # 獲取初始密碼
    log_info "ArgoCD 初始密碼："
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    echo ""
    
    # 獲取訪問 URL
    log_info "等待 LoadBalancer 分配..."
    sleep 30
    ARGOCD_URL=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    log_info "ArgoCD URL: https://$ARGOCD_URL"
}

# 安裝 GitLab Runner
install_gitlab_runner() {
    log_info "安裝 GitLab Runner..."
    
    # 添加 Helm repository
    helm repo add gitlab https://charts.gitlab.io
    helm repo update
    
    # 建立 namespace
    kubectl create namespace gitlab-runner --dry-run=client -o yaml | kubectl apply -f -
    
    # 建立配置檔案
    cat > /tmp/gitlab-runner-values.yaml <<EOF
image: gitlab/gitlab-runner:latest

rbac:
  create: true

runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "{{.Release.Namespace}}"
        image = "alpine:latest"
        privileged = true
        cpu_request = "100m"
        memory_request = "128Mi"
        cpu_limit = "500m"
        memory_limit = "512Mi"
        service_cpu_request = "100m"
        service_memory_request = "128Mi"
        service_cpu_limit = "500m"
        service_memory_limit = "512Mi"
        helper_cpu_request = "100m"
        helper_memory_request = "128Mi"
        helper_cpu_limit = "500m"
        helper_memory_limit = "512Mi"
      [runners.kubernetes.node_selector]
        "role" = "general"
      [runners.kubernetes.node_tolerations]
        "spot=true" = "NoSchedule"

resources:
  limits:
    memory: 256Mi
    cpu: 200m
  requests:
    memory: 128Mi
    cpu: 100m

nodeSelector:
  role: general

tolerations:
  - key: "spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
EOF
    
    log_warn "請提供 GitLab Runner 註冊 token（從 GitLab 專案設定中獲取）"
    read -p "GitLab Runner Token: " RUNNER_TOKEN
    read -p "GitLab URL (預設: https://gitlab.com): " GITLAB_URL
    GITLAB_URL=${GITLAB_URL:-https://gitlab.com}
    
    # 安裝 GitLab Runner
    helm upgrade --install gitlab-runner gitlab/gitlab-runner \
        --namespace gitlab-runner \
        --set gitlabUrl=$GITLAB_URL \
        --set runnerRegistrationToken="$RUNNER_TOKEN" \
        --values /tmp/gitlab-runner-values.yaml
    
    # 清理臨時檔案
    rm -f /tmp/gitlab-runner-values.yaml
    
    log_info "GitLab Runner 已安裝"
}

# 準備 Karpenter
prepare_karpenter() {
    log_info "準備 Karpenter 安裝..."
    
    # 建立 namespace
    kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -
    
    # 建立 Karpenter 配置
    cat > /tmp/karpenter-provisioner.yaml <<EOF
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  # 資源限制
  limits:
    resources:
      cpu: 1000
      memory: 1000Gi
  
  # 需求
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot", "on-demand"]
    - key: node.kubernetes.io/instance-type
      operator: In
      values:
        - t3.medium
        - t3.large
        - t3a.medium
        - t3a.large
  
  # 節點屬性
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh ${CLUSTER_NAME}
  
  # TTL 設定
  ttlSecondsAfterEmpty: 30
  ttlSecondsUntilExpired: 2592000
  
  # 標籤
  labels:
    managed-by: karpenter
    environment: test
  
  # Taints
  taints:
    - key: karpenter
      value: "true"
      effect: NoSchedule
---
apiVersion: karpenter.sh/v1alpha5
kind: AWSNodeInstanceProfile
metadata:
  name: default
spec:
  instanceProfileName: "$(terraform output -raw karpenter_instance_profile_name)"
EOF
    
    log_info "Karpenter 配置已準備，使用以下命令安裝："
    echo "helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version \"1.0.6\" \\"
    echo "  --namespace kube-system \\"
    echo "  --set serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=$(terraform output -raw karpenter_controller_role_arn) \\"
    echo "  --set settings.aws.clusterName=$CLUSTER_NAME \\"
    echo "  --set settings.aws.defaultInstanceProfile=$(terraform output -raw karpenter_instance_profile_name) \\"
    echo "  --set settings.aws.interruptionQueueName=$CLUSTER_NAME"
    echo ""
    echo "kubectl apply -f /tmp/karpenter-provisioner.yaml"
}

# 安裝監控堆疊
install_monitoring() {
    log_info "安裝 Prometheus 和 Grafana..."
    
    # 添加 Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update
    
    # 建立 namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # 安裝 Prometheus
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.retention=7d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
        --set grafana.adminPassword=admin123 \
        --set grafana.service.type=LoadBalancer
    
    log_info "Grafana 預設密碼: admin123"
    log_info "請等待 LoadBalancer 分配後訪問 Grafana"
}

# 安裝 Ingress Controller
install_ingress() {
    log_info "安裝 NGINX Ingress Controller..."
    
    # 添加 Helm repository
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    
    # 安裝 NGINX Ingress
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=LoadBalancer \
        --set controller.metrics.enabled=true \
        --set controller.nodeSelector.role=general
    
    log_info "NGINX Ingress Controller 已安裝"
}

# 主選單
show_menu() {
    echo ""
    echo "================================================"
    echo "EKS 附加元件安裝選單"
    echo "================================================"
    echo "1) 安裝 ArgoCD"
    echo "2) 安裝 GitLab Runner"
    echo "3) 準備 Karpenter"
    echo "4) 安裝監控堆疊 (Prometheus + Grafana)"
    echo "5) 安裝 Ingress Controller"
    echo "6) 安裝所有元件"
    echo "0) 退出"
    echo "================================================"
    read -p "請選擇選項: " choice
    
    case $choice in
        1) install_argocd ;;
        2) install_gitlab_runner ;;
        3) prepare_karpenter ;;
        4) install_monitoring ;;
        5) install_ingress ;;
        6) 
            install_argocd
            install_gitlab_runner
            prepare_karpenter
            install_monitoring
            install_ingress
            ;;
        0) exit 0 ;;
        *) 
            log_error "無效選項"
            show_menu
            ;;
    esac
}

# 主流程
main() {
    log_info "EKS 附加元件安裝工具"
    
    # 檢查 kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安裝"
        exit 1
    fi
    
    # 檢查 helm
    if ! command -v helm &> /dev/null; then
        log_error "Helm 未安裝"
        exit 1
    fi
    
    # 獲取集群資訊
    get_cluster_info
    
    # 顯示選單
    while true; do
        show_menu
    done
}

# 執行主流程
main