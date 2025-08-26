#!/bin/bash

# EKS + Karpenter 快速健康檢查腳本
# Author: jasontsai
# 用於日常運行狀態檢查

set -e

# 顏色定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 檢查函數
check_status() {
    local service=$1
    local status=$2
    local details=$3
    
    if [ "$status" = "OK" ]; then
        echo -e "  ${GREEN}✓${NC} $service ${GREEN}OK${NC} $details"
    elif [ "$status" = "WARN" ]; then
        echo -e "  ${YELLOW}!${NC} $service ${YELLOW}WARNING${NC} $details"
    else
        echo -e "  ${RED}✗${NC} $service ${RED}FAILED${NC} $details"
    fi
}

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}🔍 EKS + Karpenter 快速健康檢查${NC}"
echo -e "${BLUE}===============================================${NC}"
echo -e "檢查時間: $(date)"
echo ""

# 1. 集群連接檢查
echo -e "${BLUE}📡 集群連接狀態${NC}"
if kubectl cluster-info &>/dev/null; then
    check_status "Kubernetes API" "OK"
    CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)
    echo -e "  📝 集群名稱: $CLUSTER_NAME"
else
    check_status "Kubernetes API" "FAILED" "無法連接到集群"
    exit 1
fi
echo ""

# 2. 節點狀態檢查
echo -e "${BLUE}🖥️  節點狀態${NC}"
node_count=$(kubectl get nodes --no-headers | wc -l)
ready_nodes=$(kubectl get nodes --no-headers | grep -c Ready || echo "0")
not_ready_nodes=$((node_count - ready_nodes))

check_status "總節點數" "OK" "($node_count)"
if [ $ready_nodes -eq $node_count ]; then
    check_status "就緒節點" "OK" "($ready_nodes/$node_count)"
else
    check_status "就緒節點" "WARN" "($ready_nodes/$node_count, $not_ready_nodes 個節點未就緒)"
fi

# 顯示節點詳情
echo -e "  📋 節點詳情:"
kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLES:.metadata.labels['kubernetes\.io/os'],VERSION:.status.nodeInfo.kubeletVersion,INSTANCE-TYPE:.metadata.labels['node\.kubernetes\.io/instance-type']" --no-headers | while read -r line; do
    echo -e "     • $line"
done
echo ""

# 3. Karpenter 狀態檢查
echo -e "${BLUE}🚀 Karpenter 狀態${NC}"

# 檢查 Karpenter Pod
karpenter_pods=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null || echo "")
if [ -n "$karpenter_pods" ]; then
    running_pods=$(echo "$karpenter_pods" | grep -c Running || echo "0")
    total_pods=$(echo "$karpenter_pods" | wc -l)
    
    if [ $running_pods -eq $total_pods ]; then
        check_status "Karpenter Controller" "OK" "($running_pods/$total_pods pods running)"
    else
        check_status "Karpenter Controller" "WARN" "($running_pods/$total_pods pods running)"
    fi
else
    check_status "Karpenter Controller" "FAILED" "(namespace not found or no pods)"
fi

# 檢查 NodePool 配置
nodepools=$(kubectl get nodepools --no-headers 2>/dev/null | wc -l || echo "0")
if [ $nodepools -gt 0 ]; then
    check_status "NodePool 配置" "OK" "($nodepools 個)"
    kubectl get nodepools -o custom-columns="NAME:.metadata.name,READY:.status.conditions[-1].status" --no-headers 2>/dev/null | while read -r line; do
        echo -e "     • NodePool: $line"
    done
else
    check_status "NodePool 配置" "WARN" "(未找到 NodePool)"
fi

# 檢查 EC2NodeClass 配置
ec2nodeclasses=$(kubectl get ec2nodeclasses --no-headers 2>/dev/null | wc -l || echo "0")
if [ $ec2nodeclasses -gt 0 ]; then
    check_status "EC2NodeClass 配置" "OK" "($ec2nodeclasses 個)"
else
    check_status "EC2NodeClass 配置" "WARN" "(未找到 EC2NodeClass)"
fi

# 檢查 NodeClaim
nodeclaims=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l || echo "0")
if [ $nodeclaims -gt 0 ]; then
    check_status "NodeClaim 狀態" "OK" "($nodeclaims 個活動中)"
    kubectl get nodeclaims -o custom-columns="NAME:.metadata.name,TYPE:.spec.requirements[?(@.key=='node.kubernetes.io/instance-type')].values[0],READY:.status.conditions[-1].status" --no-headers 2>/dev/null | while read -r line; do
        echo -e "     • NodeClaim: $line"
    done
else
    check_status "NodeClaim 狀態" "OK" "(無活動 NodeClaim - 正常)"
fi
echo ""

# 4. 核心服務檢查
echo -e "${BLUE}⚙️  核心服務狀態${NC}"

# CoreDNS
coredns_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep -c Running || echo "0")
if [ $coredns_pods -gt 0 ]; then
    check_status "CoreDNS" "OK" "($coredns_pods pods running)"
else
    check_status "CoreDNS" "FAILED" "(no running pods)"
fi

# AWS Load Balancer Controller
alb_pods=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null | grep -c Running || echo "0")
if [ $alb_pods -gt 0 ]; then
    check_status "AWS Load Balancer Controller" "OK" "($alb_pods pods running)"
else
    check_status "AWS Load Balancer Controller" "WARN" "(未安裝或未運行)"
fi

# EBS CSI Driver
ebs_csi_pods=$(kubectl get pods -n kube-system -l app=ebs-csi-controller --no-headers 2>/dev/null | grep -c Running || echo "0")
if [ $ebs_csi_pods -gt 0 ]; then
    check_status "EBS CSI Driver" "OK" "($ebs_csi_pods pods running)"
else
    check_status "EBS CSI Driver" "WARN" "(未安裝或未運行)"
fi
echo ""

# 5. 資源使用情況
echo -e "${BLUE}📊 資源使用情況${NC}"
if kubectl top nodes &>/dev/null; then
    echo -e "  💻 節點資源使用:"
    kubectl top nodes --no-headers | while read -r node cpu memory; do
        echo -e "     • $node: CPU ${cpu}, Memory ${memory}"
    done
    
    echo -e "  🎛️  Pod 資源使用 (Top 5):"
    kubectl top pods --all-namespaces --no-headers 2>/dev/null | sort -k3 -nr | head -5 | while read -r namespace pod cpu memory; do
        echo -e "     • $namespace/$pod: CPU ${cpu}, Memory ${memory}"
    done
else
    check_status "資源監控" "WARN" "(Metrics Server 未安裝)"
fi
echo ""

# 6. 最近的告警或錯誤
echo -e "${BLUE}⚠️  最近的事件${NC}"
recent_warnings=$(kubectl get events --all-namespaces --field-selector type=Warning --no-headers 2>/dev/null | head -3)
if [ -n "$recent_warnings" ]; then
    echo -e "  🔶 最近的警告事件:"
    echo "$recent_warnings" | while read -r line; do
        echo -e "     • $line"
    done
else
    check_status "系統事件" "OK" "(無最近警告)"
fi

# Karpenter 最近日誌
echo -e "  📝 Karpenter 最近日誌 (最後 5 行):"
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=5 2>/dev/null | sed 's/^/     /' || echo "     無法獲取日誌"
echo ""

# 7. 成本優化建議
echo -e "${BLUE}💰 成本優化建議${NC}"

# 檢查 Spot 實例使用情況
spot_nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.labels.karpenter\.sh/capacity-type}' | grep -o spot | wc -l || echo "0")
total_karpenter_nodes=$(kubectl get nodes -l karpenter.sh/nodepool --no-headers | wc -l || echo "0")

if [ $total_karpenter_nodes -gt 0 ]; then
    spot_percentage=$(echo "scale=2; $spot_nodes * 100 / $total_karpenter_nodes" | bc -l 2>/dev/null || echo "0")
    echo -e "  📈 Spot 實例使用率: ${spot_percentage}% ($spot_nodes/$total_karpenter_nodes)"
    
    if (( $(echo "$spot_percentage < 70" | bc -l) )); then
        check_status "成本優化" "WARN" "建議增加 Spot 實例使用率以降低成本"
    else
        check_status "成本優化" "OK" "Spot 實例使用率良好"
    fi
else
    check_status "成本分析" "OK" "無 Karpenter 管理的節點"
fi
echo ""

# 8. 總體健康評分
echo -e "${BLUE}🏥 總體健康評分${NC}"

# 計算健康分數（簡化版）
health_score=100

# 節點健康扣分
if [ $not_ready_nodes -gt 0 ]; then
    health_score=$((health_score - not_ready_nodes * 20))
fi

# Karpenter 健康扣分
if [ $running_pods -ne $total_pods ] && [ $total_pods -gt 0 ]; then
    health_score=$((health_score - 20))
fi

# 核心服務扣分
if [ $coredns_pods -eq 0 ]; then
    health_score=$((health_score - 30))
fi

# 確保分數不低於 0
if [ $health_score -lt 0 ]; then
    health_score=0
fi

if [ $health_score -ge 90 ]; then
    echo -e "  🟢 健康評分: ${GREEN}${health_score}/100${NC} - 優秀"
elif [ $health_score -ge 70 ]; then
    echo -e "  🟡 健康評分: ${YELLOW}${health_score}/100${NC} - 良好"
else
    echo -e "  🔴 健康評分: ${RED}${health_score}/100${NC} - 需要關注"
fi

echo ""
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}✅ 健康檢查完成${NC}"
echo -e "${BLUE}===============================================${NC}"

# 提供下一步建議
echo ""
echo -e "${BLUE}🔧 建議的下一步操作:${NC}"
if [ $health_score -lt 70 ]; then
    echo -e "  • 檢查失敗的服務並進行故障排除"
    echo -e "  • 查看詳細的事件和日誌"
    echo -e "  • 運行完整測試: ./scripts/comprehensive-testing.sh"
elif [ $health_score -lt 90 ]; then
    echo -e "  • 關注警告項目並考慮改進"
    echo -e "  • 定期監控資源使用情況"
else
    echo -e "  • 系統運行良好，保持定期檢查"
    echo -e "  • 考慮運行性能測試和災難恢復演練"
fi

echo ""
echo -e "📖 更多資訊:"
echo -e "  • 完整測試: ./scripts/comprehensive-testing.sh"
echo -e "  • Karpenter 升級: ./scripts/upgrade-karpenter-v162.sh"
echo -e "  • 監控成本: ./scripts/monitor-costs.sh"