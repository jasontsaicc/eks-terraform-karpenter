#!/bin/bash

# Monitor EKS and Karpenter Costs
# Author: jasontsai

echo "=== EKS 成本監控報告 ==="
echo "生成時間: $(date)"
echo ""

export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export KUBECONFIG=/tmp/eks-config

# Get current date and last month
CURRENT_DATE=$(date +%Y-%m-%d)
MONTH_START=$(date -d "$(date +%Y-%m-01)" +%Y-%m-%d)
LAST_MONTH_START=$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m-%d)
LAST_MONTH_END=$(date -d "$(date +%Y-%m-01) -1 day" +%Y-%m-%d)

# Function to get costs
get_costs() {
    local start=$1
    local end=$2
    local service=$3
    
    aws ce get-cost-and-usage \
        --time-period Start=$start,End=$end \
        --granularity MONTHLY \
        --metrics "BlendedCost" \
        --group-by Type=DIMENSION,Key=SERVICE \
        --filter "{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"$service\"]}}" \
        --query 'ResultsByTime[0].Groups[0].Metrics.BlendedCost.Amount' \
        --output text 2>/dev/null || echo "0"
}

# 1. Node Information
echo "1. 節點資訊"
echo "=================="
echo "系統節點 (Always On):"
kubectl get nodes -l role=system -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,AGE:.status.conditions[?(@.type==\"Ready\")].lastTransitionTime --no-headers 2>/dev/null || echo "無系統節點"

echo ""
echo "應用節點 (Karpenter):"
kubectl get nodes -l node-role=application -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type,AGE:.status.conditions[?(@.type==\"Ready\")].lastTransitionTime --no-headers 2>/dev/null || echo "無應用節點"

echo ""
echo "Runner節點 (Karpenter):"
kubectl get nodes -l node-role=gitlab-runner -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type,AGE:.status.conditions[?(@.type==\"Ready\")].lastTransitionTime --no-headers 2>/dev/null || echo "無Runner節點"

# 2. Resource Usage
echo ""
echo "2. 資源使用情況"
echo "=================="
echo "節點資源使用:"
kubectl top nodes 2>/dev/null || echo "Metrics Server 未安裝"

echo ""
echo "各 Namespace Pod 數量:"
kubectl get pods -A -o json | jq -r '.items | group_by(.metadata.namespace) | .[] | "\(.[0].metadata.namespace): \(length) pods"' 2>/dev/null

# 3. Karpenter Status
echo ""
echo "3. Karpenter 狀態"
echo "=================="
echo "NodePools:"
kubectl get nodepools -A 2>/dev/null || echo "無 NodePools"

echo ""
echo "Karpenter Pods:"
kubectl get pods -n karpenter 2>/dev/null || echo "Karpenter 未安裝"

# 4. Cost Estimation
echo ""
echo "4. 成本預估 (每月 USD)"
echo "=================="

# Count nodes and calculate costs
SYSTEM_NODES=$(kubectl get nodes -l role=system --no-headers 2>/dev/null | wc -l)
APP_NODES=$(kubectl get nodes -l node-role=application --no-headers 2>/dev/null | wc -l)
RUNNER_NODES=$(kubectl get nodes -l node-role=gitlab-runner --no-headers 2>/dev/null | wc -l)

# Cost per hour (approximate)
T3_SMALL_HOUR=0.0208    # t3.small on-demand
T3_MEDIUM_HOUR=0.0416   # t3.medium on-demand
T3_MEDIUM_SPOT=0.0125   # t3.medium spot (70% discount)
T3_LARGE_SPOT=0.025     # t3.large spot (70% discount)
EKS_HOUR=0.10           # EKS control plane
NAT_HOUR=0.045          # NAT Gateway

# Calculate monthly costs (730 hours)
SYSTEM_COST=$(echo "$SYSTEM_NODES * $T3_SMALL_HOUR * 730" | bc -l 2>/dev/null || echo "0")
APP_COST=$(echo "$APP_NODES * $T3_MEDIUM_SPOT * 730" | bc -l 2>/dev/null || echo "0")
RUNNER_COST=$(echo "$RUNNER_NODES * $T3_LARGE_SPOT * 730" | bc -l 2>/dev/null || echo "0")
EKS_COST=$(echo "$EKS_HOUR * 730" | bc -l)
NAT_COST=$(echo "$NAT_HOUR * 730" | bc -l)

echo "當前運行成本:"
printf "系統節點 (%d x t3.small): \$%.2f\n" $SYSTEM_NODES $SYSTEM_COST
printf "應用節點 (%d x t3.medium SPOT): \$%.2f\n" $APP_NODES $APP_COST
printf "Runner節點 (%d x t3.large SPOT): \$%.2f\n" $RUNNER_NODES $RUNNER_COST
printf "EKS Control Plane: \$%.2f\n" $EKS_COST
printf "NAT Gateway: \$%.2f\n" $NAT_COST

TOTAL_COST=$(echo "$SYSTEM_COST + $APP_COST + $RUNNER_COST + $EKS_COST + $NAT_COST" | bc -l)
printf "總計: \$%.2f\n" $TOTAL_COST

# 5. Optimization Recommendations
echo ""
echo "5. 優化建議"
echo "=================="

if [ $APP_NODES -gt 0 ] && [ $(date +%H) -ge 19 -o $(date +%H) -lt 8 ]; then
    echo "⚠️ 當前是下班時間，但仍有 $APP_NODES 個應用節點運行"
    echo "   建議: 執行時間排程縮減節點"
fi

if [ $RUNNER_NODES -gt 0 ]; then
    RUNNER_PODS=$(kubectl get pods -l app=gitlab-runner --no-headers 2>/dev/null | wc -l)
    if [ $RUNNER_PODS -eq 0 ]; then
        echo "⚠️ 有 $RUNNER_NODES 個 Runner 節點但無 Runner Pod"
        echo "   建議: 檢查 ttlSecondsAfterEmpty 設置"
    fi
fi

SPOT_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels."karpenter.sh/capacity-type" == "spot") | .metadata.name' | wc -l)
ONDEMAND_NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels."karpenter.sh/capacity-type" == "on-demand") | .metadata.name' | wc -l)

if [ $ONDEMAND_NODES -gt 0 ] && [ $SPOT_NODES -eq 0 ]; then
    echo "⚠️ 所有 Karpenter 節點都是 On-Demand"
    echo "   建議: 優先使用 SPOT 實例節省 70% 成本"
fi

# 6. Schedule Status
echo ""
echo "6. 排程狀態"
echo "=================="
echo "已配置的 CronJobs:"
kubectl get cronjobs -n karpenter 2>/dev/null || echo "無排程任務"

# 7. Cost Comparison
echo ""
echo "7. 成本對比"
echo "=================="
echo "傳統 24/7 運行成本 (2 x t3.medium):"
TRADITIONAL_COST=$(echo "2 * $T3_MEDIUM_HOUR * 730 + $EKS_COST + $NAT_COST" | bc -l)
printf "每月: \$%.2f\n" $TRADITIONAL_COST

echo ""
echo "優化後成本 (Karpenter + 時間排程):"
# Assume 40% uptime for work hours
OPTIMIZED_APP_COST=$(echo "$T3_MEDIUM_SPOT * 730 * 0.4" | bc -l)
OPTIMIZED_TOTAL=$(echo "$SYSTEM_COST + $OPTIMIZED_APP_COST + $EKS_COST + $NAT_COST" | bc -l)
printf "每月: \$%.2f\n" $OPTIMIZED_TOTAL

SAVINGS=$(echo "$TRADITIONAL_COST - $OPTIMIZED_TOTAL" | bc -l)
SAVINGS_PERCENT=$(echo "scale=1; $SAVINGS / $TRADITIONAL_COST * 100" | bc -l)
printf "節省: \$%.2f (%.1f%%)\n" $SAVINGS $SAVINGS_PERCENT

echo ""
echo "=== 報告結束 ==="