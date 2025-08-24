#!/bin/bash
# 成本優化腳本
# 作者: jasontsai
# 用途: 實施成本優化策略

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

log_cost() {
    echo -e "${BLUE}[COST]${NC} $1"
}

# 獲取當前成本
get_current_costs() {
    log_info "分析當前成本..."
    
    # 獲取節點資訊
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local spot_nodes=$(kubectl get nodes -l node.kubernetes.io/lifecycle=spot --no-headers | wc -l)
    local on_demand_nodes=$((node_count - spot_nodes))
    
    log_cost "總節點數: $node_count"
    log_cost "On-Demand 節點: $on_demand_nodes"
    log_cost "Spot 節點: $spot_nodes"
    
    # 計算預估成本（以 t3.medium 為例）
    local on_demand_hourly=0.0416  # USD per hour
    local spot_hourly=0.0125        # USD per hour (約 30% 價格)
    
    local daily_on_demand=$(echo "$on_demand_nodes * $on_demand_hourly * 24" | bc -l)
    local daily_spot=$(echo "$spot_nodes * $spot_hourly * 24" | bc -l)
    local daily_total=$(echo "$daily_on_demand + $daily_spot" | bc -l)
    
    log_cost "預估每日成本: \$$(printf "%.2f" $daily_total) USD"
    log_cost "  - On-Demand: \$$(printf "%.2f" $daily_on_demand) USD"
    log_cost "  - Spot: \$$(printf "%.2f" $daily_spot) USD"
    
    # 檢查未使用的資源
    check_unused_resources
}

# 檢查未使用的資源
check_unused_resources() {
    log_info "檢查未使用的資源..."
    
    # 檢查未使用的 PV
    local unused_pvs=$(kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Available") | .metadata.name')
    if [ ! -z "$unused_pvs" ]; then
        log_warn "發現未使用的 Persistent Volumes:"
        echo "$unused_pvs"
    fi
    
    # 檢查未使用的 LoadBalancer
    local unused_lbs=$(kubectl get svc --all-namespaces -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer" and .status.loadBalancer.ingress == null) | "\(.metadata.namespace)/\(.metadata.name)"')
    if [ ! -z "$unused_lbs" ]; then
        log_warn "發現未使用的 LoadBalancer Services:"
        echo "$unused_lbs"
    fi
    
    # 檢查過大的 PVC
    kubectl get pvc --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name): \(.spec.resources.requests.storage)"' | while read pvc; do
        local size=$(echo $pvc | awk -F': ' '{print $2}')
        local size_gb=$(echo $size | sed 's/Gi//g')
        if [ "$size_gb" -gt "50" ] 2>/dev/null; then
            log_warn "大型 PVC: $pvc"
        fi
    done
}

# 優化節點配置
optimize_nodes() {
    log_info "優化節點配置..."
    
    # 調整 Karpenter 設定以優先使用 Spot
    cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: cost-optimized
  namespace: karpenter
spec:
  template:
    metadata:
      labels:
        karpenter.sh/pool: cost-optimized
        node.kubernetes.io/lifecycle: spot
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values:
            - t3.small
            - t3a.small
            - t2.small
      
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: spot
      
      taints:
        - key: spot
          value: "true"
          effect: NoSchedule
  
  limits:
    cpu: "1000"
    memory: "1000Gi"
  
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 5m
    consolidateAfter: 30s
EOF
    
    log_info "節點配置已優化為優先使用 Spot 實例"
}

# 設定自動縮放策略
configure_autoscaling() {
    log_info "配置自動縮放策略..."
    
    # 配置 HPA
    local deployments=$(kubectl get deployments --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"')
    
    for deployment in $deployments; do
        local ns=$(echo $deployment | cut -d'/' -f1)
        local name=$(echo $deployment | cut -d'/' -f2)
        
        # 跳過系統元件
        if [[ "$ns" == "kube-system" ]] || [[ "$ns" == "karpenter" ]]; then
            continue
        fi
        
        # 檢查是否已有 HPA
        if ! kubectl get hpa $name -n $ns &>/dev/null; then
            log_info "為 $deployment 創建 HPA"
            kubectl autoscale deployment $name -n $ns --min=1 --max=5 --cpu-percent=70 2>/dev/null || true
        fi
    done
}

# 優化儲存
optimize_storage() {
    log_info "優化儲存配置..."
    
    # 將 gp2 轉換為 gp3
    kubectl get sc -o json | jq -r '.items[] | select(.provisioner == "ebs.csi.aws.com" and .parameters.type == "gp2") | .metadata.name' | while read sc; do
        log_info "建議將 StorageClass $sc 從 gp2 升級到 gp3"
    done
    
    # 清理未使用的 PV
    kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Released") | .metadata.name' | while read pv; do
        log_warn "發現已釋放的 PV: $pv，建議刪除"
        read -p "是否刪除 PV $pv? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kubectl delete pv $pv
            log_info "已刪除 PV: $pv"
        fi
    done
}

# 優化網路
optimize_networking() {
    log_info "優化網路配置..."
    
    # 檢查未使用的 Ingress
    kubectl get ingress --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | while read ingress; do
        local ns=$(echo $ingress | cut -d'/' -f1)
        local name=$(echo $ingress | cut -d'/' -f2)
        
        # 檢查後端服務是否存在
        local backend_exists=true
        kubectl get ingress $name -n $ns -o json | jq -r '.spec.rules[].http.paths[].backend.service.name' | while read svc; do
            if ! kubectl get svc $svc -n $ns &>/dev/null; then
                backend_exists=false
                log_warn "Ingress $ingress 的後端服務 $svc 不存在"
            fi
        done
    done
    
    # 建議使用 NLB 替代 ALB（成本較低）
    log_info "建議：對於簡單的 TCP/UDP 流量，使用 NLB 替代 ALB 可節省成本"
}

# 設定成本告警
setup_cost_alerts() {
    log_info "設定成本告警..."
    
    # 創建 CloudWatch 告警
    aws cloudwatch put-metric-alarm \
        --alarm-name "EKS-Daily-Cost-Alert" \
        --alarm-description "Alert when EKS daily cost exceeds threshold" \
        --metric-name EstimatedCharges \
        --namespace AWS/Billing \
        --statistic Maximum \
        --period 86400 \
        --threshold 50 \
        --comparison-operator GreaterThanThreshold \
        --dimensions Name=Currency,Value=USD \
        --evaluation-periods 1 \
        --treat-missing-data notBreaching \
        2>/dev/null || log_warn "CloudWatch 告警可能已存在"
    
    log_info "成本告警已設定（閾值: \$50/天）"
}

# 生成成本報告
generate_cost_report() {
    log_info "生成成本優化報告..."
    
    local report_file="cost-optimization-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "================================================"
        echo "成本優化報告"
        echo "生成時間: $(date)"
        echo "================================================"
        echo ""
        echo "## 當前資源使用情況"
        echo ""
        kubectl top nodes 2>/dev/null || echo "metrics-server 未安裝"
        echo ""
        echo "## 節點分布"
        kubectl get nodes -L node.kubernetes.io/instance-type,node.kubernetes.io/lifecycle
        echo ""
        echo "## 命名空間資源使用"
        kubectl get ns -o json | jq -r '.items[].metadata.name' | while read ns; do
            echo "### Namespace: $ns"
            kubectl top pods -n $ns 2>/dev/null || true
            echo ""
        done
        echo ""
        echo "## 優化建議"
        echo "1. 使用 Spot 實例替代 On-Demand 實例"
        echo "2. 實施積極的自動縮放策略"
        echo "3. 使用 gp3 替代 gp2 儲存"
        echo "4. 定期清理未使用的資源"
        echo "5. 考慮使用 Reserved Instances 或 Savings Plans"
        echo ""
        echo "================================================"
    } > $report_file
    
    log_info "報告已生成: $report_file"
}

# 實施激進成本優化
aggressive_optimization() {
    log_warn "執行激進成本優化（可能影響可用性）..."
    
    read -p "確定要執行激進優化嗎？這可能會影響服務可用性 (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "取消激進優化"
        return
    fi
    
    # 1. 將所有節點切換到 Spot
    log_info "強制所有工作負載使用 Spot 節點..."
    kubectl get deployments --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
        if [[ "$ns" == "kube-system" ]]; then
            continue
        fi
        kubectl patch deployment $name -n $ns --type='json' -p='[{"op": "add", "path": "/spec/template/spec/tolerations", "value": [{"key": "spot", "operator": "Equal", "value": "true", "effect": "NoSchedule"}]}]' 2>/dev/null || true
    done
    
    # 2. 降低副本數
    log_info "降低非關鍵服務的副本數..."
    kubectl get deployments --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | while read ns name; do
        if [[ "$ns" == "kube-system" ]] || [[ "$ns" == "karpenter" ]]; then
            continue
        fi
        local replicas=$(kubectl get deployment $name -n $ns -o jsonpath='{.spec.replicas}')
        if [ "$replicas" -gt "1" ]; then
            kubectl scale deployment $name -n $ns --replicas=1
            log_info "降低 $ns/$name 副本數到 1"
        fi
    done
    
    # 3. 刪除未使用的資源
    log_info "清理所有未使用的資源..."
    kubectl get pv -o json | jq -r '.items[] | select(.status.phase == "Available" or .status.phase == "Released") | .metadata.name' | while read pv; do
        kubectl delete pv $pv
        log_info "刪除未使用的 PV: $pv"
    done
}

# 主選單
show_menu() {
    echo ""
    echo "========================================="
    echo "EKS 成本優化工具"
    echo "========================================="
    echo "1. 分析當前成本"
    echo "2. 優化節點配置"
    echo "3. 配置自動縮放"
    echo "4. 優化儲存"
    echo "5. 優化網路"
    echo "6. 設定成本告警"
    echo "7. 生成成本報告"
    echo "8. 執行完整優化（推薦）"
    echo "9. 激進成本優化（謹慎使用）"
    echo "0. 退出"
    echo "========================================="
    read -p "請選擇操作 [0-9]: " choice
}

# 執行完整優化
full_optimization() {
    log_info "執行完整成本優化..."
    get_current_costs
    optimize_nodes
    configure_autoscaling
    optimize_storage
    optimize_networking
    setup_cost_alerts
    generate_cost_report
    log_info "完整優化完成！"
}

# 主函數
main() {
    while true; do
        show_menu
        case $choice in
            1) get_current_costs ;;
            2) optimize_nodes ;;
            3) configure_autoscaling ;;
            4) optimize_storage ;;
            5) optimize_networking ;;
            6) setup_cost_alerts ;;
            7) generate_cost_report ;;
            8) full_optimization ;;
            9) aggressive_optimization ;;
            0) 
                log_info "退出成本優化工具"
                exit 0
                ;;
            *)
                log_error "無效的選擇"
                ;;
        esac
    done
}

# 執行主函數
main "$@"