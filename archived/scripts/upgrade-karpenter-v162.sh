#!/bin/bash

# Karpenter v1.6.2 升級腳本
# Author: jasontsai
# 支援從舊版本升級到 v1.6.2

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日誌函數
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 檢查必要工具
check_prerequisites() {
    log_step "檢查必要工具..."
    
    for tool in kubectl helm aws terraform; do
        if ! command -v $tool &> /dev/null; then
            log_error "$tool 未安裝或不在 PATH 中"
            exit 1
        fi
    done
    
    # 檢查 kubectl 連接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "kubectl 無法連接到集群"
        exit 1
    fi
    
    log_info "所有必要工具檢查通過"
}

# 獲取集群資訊
get_cluster_info() {
    log_step "獲取集群資訊..."
    
    export AWS_REGION=ap-southeast-1
    export CLUSTER_NAME=eks-lab-test-eks
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    # 從 terraform 獲取輸出
    export CLUSTER_ENDPOINT=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.endpoint" --output text)
    export OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.identity.oidc.issuer" --output text)
    export OIDC_ID=$(echo $OIDC_URL | cut -d '/' -f 5)
    
    log_info "集群名稱: $CLUSTER_NAME"
    log_info "區域: $AWS_REGION"
    log_info "AWS 帳戶 ID: $AWS_ACCOUNT_ID"
    log_info "OIDC ID: $OIDC_ID"
}

# 備份現有配置
backup_existing_config() {
    log_step "備份現有 Karpenter 配置..."
    
    local backup_dir="./karpenter-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 備份現有的 Karpenter 資源
    kubectl get nodepools -A -o yaml > "$backup_dir/nodepools.yaml" 2>/dev/null || true
    kubectl get ec2nodeclasses -A -o yaml > "$backup_dir/ec2nodeclasses.yaml" 2>/dev/null || true
    kubectl get nodeclaims -A -o yaml > "$backup_dir/nodeclaims.yaml" 2>/dev/null || true
    
    # 備份 Helm values
    helm get values karpenter -n kube-system > "$backup_dir/helm-values.yaml" 2>/dev/null || true
    helm get values karpenter -n karpenter > "$backup_dir/helm-values-karpenter-ns.yaml" 2>/dev/null || true
    
    log_info "備份儲存於: $backup_dir"
    export BACKUP_DIR="$backup_dir"
}

# 更新 Terraform 配置
update_terraform_config() {
    log_step "更新 Terraform 配置..."
    
    # 應用 Terraform 變更以啟用 IAM 角色
    terraform plan -out=karpenter-upgrade.tfplan
    
    if terraform apply karpenter-upgrade.tfplan; then
        log_info "Terraform 配置更新成功"
        rm -f karpenter-upgrade.tfplan
    else
        log_error "Terraform 配置更新失敗"
        exit 1
    fi
    
    # 獲取新的 IAM 角色 ARN
    export KARPENTER_IAM_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
    export AWS_LB_CONTROLLER_IAM_ROLE_ARN=$(terraform output -raw aws_load_balancer_controller_role_arn)
    export KARPENTER_INSTANCE_PROFILE=$(terraform output -raw karpenter_instance_profile_name)
    
    log_info "Karpenter IAM 角色: $KARPENTER_IAM_ROLE_ARN"
    log_info "實例配置檔: $KARPENTER_INSTANCE_PROFILE"
}

# 清理舊版本
cleanup_old_version() {
    log_step "清理舊版本 Karpenter..."
    
    # 檢查現有安裝
    if helm list -n kube-system | grep -q karpenter; then
        log_warn "發現 kube-system namespace 中的 Karpenter，進行清理..."
        
        # 優雅地刪除舊的 Provisioner 和 AWSNodePool 資源
        kubectl delete provisioners --all --timeout=60s 2>/dev/null || true
        kubectl delete awsnodepools --all --timeout=60s 2>/dev/null || true
        
        # 卸載 Helm release
        helm uninstall karpenter -n kube-system
    fi
    
    if helm list -n karpenter | grep -q karpenter; then
        log_warn "發現 karpenter namespace 中的舊版本，進行清理..."
        
        # 保存現有 NodePool 和 EC2NodeClass（如果與新版本兼容）
        kubectl get nodepools -n karpenter -o yaml > /tmp/existing-nodepools.yaml 2>/dev/null || true
        kubectl get ec2nodeclasses -n karpenter -o yaml > /tmp/existing-ec2nodeclasses.yaml 2>/dev/null || true
        
        # 卸載舊版本
        helm uninstall karpenter -n karpenter
    fi
    
    # 等待資源清理
    sleep 30
}

# 安裝新版本 CRDs
install_new_crds() {
    log_step "安裝 Karpenter v1.6.2 CRDs..."
    
    # 安裝最新 CRDs
    kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.sh_nodepools.yaml
    kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.sh_nodeclaims.yaml
    kubectl apply -f https://raw.githubusercontent.com/aws/karpenter-provider-aws/v1.6.2/pkg/apis/crds/karpenter.k8s.aws_ec2nodeclasses.yaml
    
    log_info "CRDs 安裝完成"
}

# 創建 SQS 中斷佇列
create_interruption_queue() {
    log_step "創建 SQS 中斷佇列..."
    
    # 創建 SQS 佇列
    aws sqs create-queue \
        --queue-name "${CLUSTER_NAME}" \
        --region ${AWS_REGION} \
        --attributes MessageRetentionPeriod=300 \
        2>/dev/null || log_warn "SQS 佇列可能已存在"
    
    # 獲取佇列 URL
    export QUEUE_URL=$(aws sqs get-queue-url --queue-name "${CLUSTER_NAME}" --region ${AWS_REGION} --query 'QueueUrl' --output text)
    log_info "SQS 佇列 URL: $QUEUE_URL"
}

# 標記資源供 Karpenter 發現
tag_resources() {
    log_step "標記 AWS 資源供 Karpenter 發現..."
    
    # 獲取 VPC ID
    local vpc_id=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --query 'cluster.resourcesVpcConfig.vpcId' --output text)
    
    # 標記私有子網路
    for subnet in $(aws ec2 describe-subnets --region ${AWS_REGION} \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' --output text); do
        
        aws ec2 create-tags --region ${AWS_REGION} \
            --resources $subnet \
            --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
        
        log_info "已標記子網路: $subnet"
    done
    
    # 標記安全群組
    local cluster_sg=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
    
    aws ec2 create-tags --region ${AWS_REGION} \
        --resources $cluster_sg \
        --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
    
    log_info "已標記安全群組: $cluster_sg"
}

# 安裝 Karpenter v1.6.2
install_karpenter_v162() {
    log_step "安裝 Karpenter v1.6.2..."
    
    # 創建 namespace
    kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -
    
    # 安裝 Karpenter
    helm upgrade --install karpenter \
        oci://public.ecr.aws/karpenter/karpenter \
        --namespace karpenter \
        --version "1.6.2" \
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_IAM_ROLE_ARN}" \
        --set "settings.clusterName=${CLUSTER_NAME}" \
        --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
        --set "settings.interruptionQueue=${CLUSTER_NAME}" \
        --set "controller.resources.requests.cpu=1" \
        --set "controller.resources.requests.memory=1Gi" \
        --set "controller.resources.limits.cpu=2" \
        --set "controller.resources.limits.memory=2Gi" \
        --set "replicas=2" \
        --set "logLevel=info" \
        --set "webhook.enabled=true" \
        --set "webhook.port=8443" \
        --wait --timeout=300s
    
    if [ $? -eq 0 ]; then
        log_info "Karpenter v1.6.2 安裝成功"
    else
        log_error "Karpenter 安裝失敗"
        exit 1
    fi
}

# 應用 NodePool 配置
apply_nodepool_config() {
    log_step "應用 NodePool 配置..."
    
    # 使用更新的 NodePool 配置
    if [ -f "/home/ubuntu/projects/aws_eks_terraform/karpenter-nodepool-v162.yaml" ]; then
        kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/karpenter-nodepool-v162.yaml
        log_info "NodePool 配置已應用"
    else
        log_error "找不到 NodePool 配置檔案"
        exit 1
    fi
}

# 驗證安裝
verify_installation() {
    log_step "驗證 Karpenter 安裝..."
    
    # 檢查 Pod 狀態
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=karpenter -n karpenter --timeout=300s
    
    if [ $? -eq 0 ]; then
        log_info "Karpenter Pods 已就緒"
        
        # 顯示 Pod 狀態
        kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter
        
        # 檢查 CRDs
        kubectl get crd | grep karpenter
        
        # 檢查 NodePools
        kubectl get nodepools -A
        
        # 檢查 EC2NodeClasses
        kubectl get ec2nodeclasses -A
        
        log_info "✅ Karpenter v1.6.2 升級成功完成！"
    else
        log_error "❌ Karpenter 安裝驗證失敗"
        
        # 顯示故障排除資訊
        echo ""
        log_warn "故障排除資訊："
        kubectl get pods -n karpenter
        kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50
        
        exit 1
    fi
}

# 安裝測試應用程式
install_test_application() {
    log_step "安裝測試應用程式..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test-v162
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: karpenter-test-v162
  template:
    metadata:
      labels:
        app: karpenter-test-v162
    spec:
      tolerations:
        - key: karpenter.sh/nodepool
          value: general-purpose
          effect: NoSchedule
      nodeSelector:
        nodepool: general-purpose
      containers:
      - name: nginx
        image: nginx:1.24
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 1000m
            memory: 2Gi
        ports:
        - containerPort: 80
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: karpenter-test-v162
EOF
    
    log_info "測試應用程式已部署"
    
    # 等待 Pod 調度
    sleep 30
    kubectl get pods -l app=karpenter-test-v162 -o wide
    
    # 檢查 NodeClaims
    kubectl get nodeclaims -A
}

# 顯示升級摘要
show_upgrade_summary() {
    log_step "升級摘要"
    
    echo ""
    echo "========================================="
    echo "🎉 Karpenter v1.6.2 升級完成"
    echo "========================================="
    echo ""
    echo "📊 集群資訊："
    echo "  • 集群名稱: $CLUSTER_NAME"
    echo "  • 區域: $AWS_REGION"
    echo "  • Karpenter 版本: v1.6.2"
    echo "  • Namespace: karpenter"
    echo ""
    echo "🔑 IAM 角色："
    echo "  • Controller 角色: $KARPENTER_IAM_ROLE_ARN"
    echo "  • 實例配置檔: $KARPENTER_INSTANCE_PROFILE"
    echo ""
    echo "📋 有用的命令："
    echo "  • 檢查 Karpenter 狀態: kubectl get pods -n karpenter"
    echo "  • 檢查 NodePools: kubectl get nodepools -A"
    echo "  • 檢查 NodeClaims: kubectl get nodeclaims -A"
    echo "  • 檢查日誌: kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter"
    echo ""
    echo "🔧 備份位置: $BACKUP_DIR"
    echo ""
}

# 主函數
main() {
    echo "========================================="
    echo "🚀 Karpenter v1.6.2 升級腳本"
    echo "========================================="
    echo ""
    
    check_prerequisites
    get_cluster_info
    backup_existing_config
    update_terraform_config
    cleanup_old_version
    install_new_crds
    create_interruption_queue
    tag_resources
    install_karpenter_v162
    apply_nodepool_config
    verify_installation
    install_test_application
    show_upgrade_summary
    
    log_info "🎊 所有步驟完成！Karpenter v1.6.2 已成功部署。"
}

# 執行主函數
main "$@"