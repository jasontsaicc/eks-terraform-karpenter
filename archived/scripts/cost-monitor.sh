#!/bin/bash

# AWS 成本監控和預估腳本
# 監控 EKS + Karpenter 相關成本
# Author: jasontsai

set -e

echo "💰 AWS EKS + Karpenter 成本監控"
echo "========================================"
echo ""

# 環境變數
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks

# 獲取當前日期
CURRENT_DATE=$(date '+%Y-%m-%d')
PREVIOUS_DATE=$(date -d '1 day ago' '+%Y-%m-%d')
CURRENT_MONTH=$(date '+%Y-%m')

echo "📅 報告日期: $CURRENT_DATE"
echo "🌍 區域: $AWS_REGION"
echo "🔍 集群: $CLUSTER_NAME"
echo ""

# 1. EC2 實例成本
echo "💻 EC2 實例成本分析"
echo "----------------------------------------"

# 獲取當前運行的實例
RUNNING_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?Tags[?Key==`kubernetes.io/cluster/'$CLUSTER_NAME'`] || Tags[?Key==`karpenter.sh/cluster`]]' \
    --output json)

if [[ $(echo "$RUNNING_INSTANCES" | jq length) -gt 0 ]]; then
    echo "運行中的實例:"
    echo "$RUNNING_INSTANCES" | jq -r '.[] | [.InstanceId, .InstanceType, .State.Name, (.Tags[]? | select(.Key=="Name") | .Value // "N/A")] | @tsv' | while read -r instance_id instance_type state name; do
        # 獲取實例價格 (Spot vs On-Demand)
        if echo "$RUNNING_INSTANCES" | jq -r --arg id "$instance_id" '.[] | select(.InstanceId == $id) | .SpotInstanceRequestId' | grep -q "sir-"; then
            pricing_type="Spot"
            # 獲取 Spot 價格
            spot_price=$(aws ec2 describe-spot-price-history --region $AWS_REGION \
                --instance-types $instance_type \
                --product-descriptions "Linux/UNIX" \
                --max-items 1 \
                --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null || echo "N/A")
            echo "  $instance_id ($instance_type) - $pricing_type - \$$spot_price/hour"
        else
            pricing_type="On-Demand"
            echo "  $instance_id ($instance_type) - $pricing_type"
        fi
    done
else
    echo "無運行中的 EKS 相關實例"
fi

echo ""

# 2. Load Balancer 成本
echo "⚖️ Load Balancer 成本分析"
echo "----------------------------------------"

# 應用程式負載均衡器
ALB_COUNT=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?Type==`application`]' --output json | jq length)

if [[ $ALB_COUNT -gt 0 ]]; then
    echo "Application Load Balancers: $ALB_COUNT"
    echo "預估成本: \$$(echo "scale=2; $ALB_COUNT * 0.0225 * 24" | bc)/day"
else
    echo "無 Application Load Balancer"
fi

# 網路負載均衡器
NLB_COUNT=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query 'LoadBalancers[?Type==`network`]' --output json | jq length)

if [[ $NLB_COUNT -gt 0 ]]; then
    echo "Network Load Balancers: $NLB_COUNT"  
    echo "預估成本: \$$(echo "scale=2; $NLB_COUNT * 0.0225 * 24" | bc)/day"
else
    echo "無 Network Load Balancer"
fi

echo ""

# 3. EKS 控制平面成本
echo "🎛️ EKS 控制平面成本"
echo "----------------------------------------"

if aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
    EKS_VERSION=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.version' --output text)
    echo "EKS 集群: $CLUSTER_NAME (v$EKS_VERSION)"
    echo "控制平面成本: \$0.10/hour = \$2.40/day"
else
    echo "EKS 集群不存在"
fi

echo ""

# 4. NAT Gateway 成本
echo "🌐 NAT Gateway 成本分析"
echo "----------------------------------------"

VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")

if [[ ! -z "$VPC_ID" ]]; then
    NAT_GATEWAYS=$(aws ec2 describe-nat-gateways --region $AWS_REGION \
        --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
        --query 'NatGateways[].NatGatewayId' --output text)
    
    NAT_COUNT=$(echo "$NAT_GATEWAYS" | wc -w)
    
    if [[ $NAT_COUNT -gt 0 ]]; then
        echo "NAT Gateways: $NAT_COUNT"
        echo "預估成本: \$$(echo "scale=2; $NAT_COUNT * 0.045 * 24" | bc)/day (不含流量)"
        echo "NAT Gateway IDs: $NAT_GATEWAYS"
    else
        echo "無 NAT Gateway"
    fi
else
    echo "無法獲取 VPC 資訊"
fi

echo ""

# 5. EBS 卷成本
echo "💾 EBS 卷成本分析"
echo "----------------------------------------"

EBS_VOLUMES=$(aws ec2 describe-volumes --region $AWS_REGION \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
    --query 'Volumes[*].[VolumeId,Size,VolumeType,State]' --output text 2>/dev/null)

if [[ ! -z "$EBS_VOLUMES" ]]; then
    total_size=0
    echo "EBS 卷詳情:"
    while read -r volume_id size volume_type state; do
        if [[ ! -z "$volume_id" ]]; then
            echo "  $volume_id: ${size}GB ($volume_type) - $state"
            total_size=$((total_size + size))
        fi
    done <<< "$EBS_VOLUMES"
    
    # 按 gp3 計算 (ap-southeast-1 價格: $0.096/GB/month)
    monthly_cost=$(echo "scale=2; $total_size * 0.096" | bc)
    daily_cost=$(echo "scale=2; $monthly_cost / 30" | bc)
    echo "總容量: ${total_size}GB"
    echo "預估成本: \$$daily_cost/day (\$$monthly_cost/month)"
else
    echo "無相關的 EBS 卷"
fi

echo ""

# 6. 成本優化建議
echo "💡 成本優化建議"
echo "----------------------------------------"

# 檢查是否使用 Spot 實例
TOTAL_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?Tags[?Key==`kubernetes.io/cluster/'$CLUSTER_NAME'`]]' \
    --output json | jq length)

SPOT_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?Tags[?Key==`kubernetes.io/cluster/'$CLUSTER_NAME'`] && SpotInstanceRequestId]' \
    --output json | jq length)

if [[ $TOTAL_INSTANCES -gt 0 ]]; then
    SPOT_PERCENTAGE=$(echo "scale=0; $SPOT_INSTANCES * 100 / $TOTAL_INSTANCES" | bc)
    echo "Spot 實例使用率: $SPOT_PERCENTAGE% ($SPOT_INSTANCES/$TOTAL_INSTANCES)"
    
    if [[ $SPOT_PERCENTAGE -lt 70 ]]; then
        echo "💰 建議: 增加 Spot 實例使用率可節省高達 70% 的 EC2 成本"
    else
        echo "✅ Spot 實例使用率良好"
    fi
else
    echo "⚠️  無法計算 Spot 實例使用率"
fi

# 檢查 Karpenter 配置
if kubectl get nodepool general-purpose >/dev/null 2>&1; then
    CONSOLIDATION_POLICY=$(kubectl get nodepool general-purpose -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null)
    echo "Karpenter 整合策略: $CONSOLIDATION_POLICY"
    
    if [[ "$CONSOLIDATION_POLICY" == "WhenEmptyOrUnderutilized" ]]; then
        echo "✅ 已啟用積極的成本優化策略"
    else
        echo "💰 建議: 使用 'WhenEmptyOrUnderutilized' 整合策略以節省成本"
    fi
fi

echo ""

# 7. 預估每日/每月成本總結
echo "📊 成本總結 (ap-southeast-1 區域)"
echo "========================================"

echo "固定成本 (每日):"
echo "  • EKS 控制平面: \$2.40"
echo "  • NAT Gateway: \$1.08 (1個)"
echo "  • 小計: \$3.48"

echo ""
echo "變動成本 (基於當前配置):"

# EC2 預估 (基於 t3.medium)
if [[ $TOTAL_INSTANCES -gt 0 ]]; then
    if [[ $SPOT_PERCENTAGE -gt 50 ]]; then
        # 假設 70% Spot, 30% On-Demand
        ec2_cost=$(echo "scale=2; $TOTAL_INSTANCES * (0.7 * 0.0134 + 0.3 * 0.0456) * 24" | bc)
    else
        # 假設全部 On-Demand
        ec2_cost=$(echo "scale=2; $TOTAL_INSTANCES * 0.0456 * 24" | bc)
    fi
    echo "  • EC2 實例 ($TOTAL_INSTANCES 個): \$$ec2_cost/day"
else
    echo "  • EC2 實例: \$0 (無實例)"
fi

# ALB 成本
alb_cost=$(echo "scale=2; $ALB_COUNT * 0.0225 * 24" | bc)
echo "  • Application LB: \$$alb_cost/day"

# EBS 成本
if [[ ! -z "$daily_cost" ]]; then
    echo "  • EBS 存儲: \$$daily_cost/day"
else
    echo "  • EBS 存儲: \$0.50/day (預估)"
fi

echo ""
echo "總預估成本:"
total_daily=$(echo "scale=2; 3.48 + ${ec2_cost:-1.20} + $alb_cost + ${daily_cost:-0.50}" | bc)
total_monthly=$(echo "scale=2; $total_daily * 30" | bc)
echo "  • 每日: \$$total_daily"
echo "  • 每月: \$$total_monthly"

echo ""
echo "🔄 清理基礎設施節省:"
echo "  • 執行清理可節省: \$$total_daily/day"
echo "  • 月度節省: \$$total_monthly"

echo ""
echo "⏰ 下次檢查建議: $(date -d '+1 day' '+%Y-%m-%d')"
echo "🔧 清理命令: ./scripts/cleanup-complete.sh"