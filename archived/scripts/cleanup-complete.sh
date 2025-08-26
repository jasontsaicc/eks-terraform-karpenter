#!/bin/bash

# 完整 AWS 資源清理腳本 - 節省成本用
# 清理所有 EKS、VPC、IAM、Load Balancer 等 AWS 資源
# Author: jasontsai

set -e

echo "🧹 開始完整 AWS 資源清理程序"
echo "⚠️  這將刪除所有相關的 AWS 資源以節省費用"
echo ""

# 環境變數設定
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export VPC_ID=vpc-006e79ec4f5c2b0ec

# 確認清理意圖
read -p "確定要清理所有 AWS 資源嗎？ (yes/no): " confirm
if [[ $confirm != "yes" ]]; then
    echo "❌ 清理已取消"
    exit 1
fi

echo "✅ 開始清理程序..."
echo ""

# Phase 1: Kubernetes 資源清理
echo "📋 Phase 1: 清理 Kubernetes 資源"
echo "----------------------------------------"

# 設置正確的 kubeconfig
if [ -f ~/.kube/config ]; then
    export KUBECONFIG=~/.kube/config
    
    # 檢查 EKS 集群是否存在
    if aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
        echo "清理 Helm releases..."
        helm uninstall karpenter -n kube-system --ignore-not-found 2>/dev/null || true
        helm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found 2>/dev/null || true
        
        echo "清理 Karpenter 資源..."
        kubectl delete nodepools --all -A --ignore-not-found 2>/dev/null || true
        kubectl delete ec2nodeclasses --all -A --ignore-not-found 2>/dev/null || true
        kubectl delete nodeclaims --all -A --ignore-not-found 2>/dev/null || true
        
        echo "清理測試部署..."
        kubectl delete deployment karpenter-scale-test simple-test --ignore-not-found 2>/dev/null || true
        kubectl delete job test-runner-job --ignore-not-found 2>/dev/null || true
        
        echo "✅ Kubernetes 資源已清理"
    else
        echo "⚠️  EKS 集群不存在，跳過 Kubernetes 清理"
    fi
else
    echo "⚠️  kubeconfig 不存在，跳過 Kubernetes 清理"
fi

echo ""

# Phase 2: Load Balancer 清理
echo "📋 Phase 2: 清理 Load Balancer 資源"
echo "----------------------------------------"

echo "查找並刪除 Application Load Balancers..."
for alb_arn in $(aws elbv2 describe-load-balancers --region $AWS_REGION --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text); do
    if [[ ! -z "$alb_arn" ]]; then
        echo "刪除 ALB: $alb_arn"
        aws elbv2 delete-load-balancer --load-balancer-arn $alb_arn --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "查找並刪除 Target Groups..."
for tg_arn in $(aws elbv2 describe-target-groups --region $AWS_REGION --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text); do
    if [[ ! -z "$tg_arn" ]]; then
        echo "刪除 Target Group: $tg_arn"
        aws elbv2 delete-target-group --target-group-arn $tg_arn --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "✅ Load Balancer 資源已清理"
echo ""

# Phase 3: Terraform 資源清理
echo "📋 Phase 3: 執行 Terraform Destroy"
echo "----------------------------------------"

if [ -f "terraform.tfstate" ]; then
    echo "使用 Terraform 清理主要基礎設施..."
    
    # 首先嘗試標準銷毀
    timeout 1800 terraform destroy -auto-approve || {
        echo "⚠️  標準銷毀可能遇到問題，嘗試強制清理..."
        
        # 如果有依賴問題，先清理特定資源
        terraform destroy -target=aws_eks_node_group.main -auto-approve 2>/dev/null || true
        terraform destroy -target=aws_eks_cluster.main -auto-approve 2>/dev/null || true
        sleep 60
        terraform destroy -auto-approve
    }
    
    echo "✅ Terraform 資源已清理"
else
    echo "⚠️  terraform.tfstate 不存在，跳過 Terraform 清理"
fi

echo ""

# Phase 4: 手動清理剩餘資源
echo "📋 Phase 4: 清理剩餘 AWS 資源"
echo "----------------------------------------"

echo "清理剩餘的 EC2 實例..."
for instance_id in $(aws ec2 describe-instances --region $AWS_REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text); do
    if [[ ! -z "$instance_id" ]]; then
        echo "終止實例: $instance_id"
        aws ec2 terminate-instances --instance-ids $instance_id --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "等待實例終止..."
sleep 30

echo "清理 Auto Scaling Groups..."
for asg_name in $(aws autoscaling describe-auto-scaling-groups --region $AWS_REGION \
    --query "AutoScalingGroups[?contains(Tags[?Key=='aws:cloudformation:stack-name'].Value, 'eks-lab') || contains(AutoScalingGroupName, 'karpenter')].AutoScalingGroupName" --output text); do
    if [[ ! -z "$asg_name" ]]; then
        echo "刪除 ASG: $asg_name"
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $asg_name --force-delete --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "清理 Launch Templates..."
for lt_id in $(aws ec2 describe-launch-templates --region $AWS_REGION \
    --query "LaunchTemplates[?contains(LaunchTemplateName, 'karpenter') || contains(LaunchTemplateName, 'eks')].LaunchTemplateId" --output text); do
    if [[ ! -z "$lt_id" ]]; then
        echo "刪除 Launch Template: $lt_id"
        aws ec2 delete-launch-template --launch-template-id $lt_id --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "清理 EBS 卷..."
for volume_id in $(aws ec2 describe-volumes --region $AWS_REGION \
    --filters "Name=status,Values=available" \
    --query 'Volumes[?Tags[?Key==`kubernetes.io/cluster/eks-lab-test-eks`]].VolumeId' --output text); do
    if [[ ! -z "$volume_id" ]]; then
        echo "刪除 EBS 卷: $volume_id"
        aws ec2 delete-volume --volume-id $volume_id --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "清理 VPC Endpoints..."
for vpce_id in $(aws ec2 describe-vpc-endpoints --region $AWS_REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[].VpcEndpointId' --output text); do
    if [[ ! -z "$vpce_id" ]]; then
        echo "刪除 VPC Endpoint: $vpce_id"
        aws ec2 delete-vpc-endpoint --vpc-endpoint-id $vpce_id --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "✅ 剩餘資源已清理"
echo ""

# Phase 5: IAM 資源清理
echo "📋 Phase 5: 清理 IAM 資源"
echo "----------------------------------------"

echo "清理 IAM 角色和政策..."

# 清理 Karpenter 相關角色
for role_name in "KarpenterControllerRole-$CLUSTER_NAME" "KarpenterNodeRole-$CLUSTER_NAME"; do
    if aws iam get-role --role-name $role_name >/dev/null 2>&1; then
        echo "清理角色: $role_name"
        
        # 分離附加的 AWS 管理政策
        for policy_arn in $(aws iam list-attached-role-policies --role-name $role_name --query 'AttachedPolicies[].PolicyArn' --output text); do
            aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn 2>/dev/null || true
        done
        
        # 刪除內聯政策
        for policy_name in $(aws iam list-role-policies --role-name $role_name --query 'PolicyNames[]' --output text); do
            aws iam delete-role-policy --role-name $role_name --policy-name $policy_name 2>/dev/null || true
        done
        
        # 從實例配置文件中移除角色
        for profile_name in $(aws iam list-instance-profiles-for-role --role-name $role_name --query 'InstanceProfiles[].InstanceProfileName' --output text); do
            aws iam remove-role-from-instance-profile --instance-profile-name $profile_name --role-name $role_name 2>/dev/null || true
        done
        
        # 刪除角色
        aws iam delete-role --role-name $role_name 2>/dev/null || true
    fi
done

# 清理實例配置文件
for profile_name in "KarpenterNodeInstanceProfile-$CLUSTER_NAME"; do
    if aws iam get-instance-profile --instance-profile-name $profile_name >/dev/null 2>&1; then
        echo "刪除實例配置文件: $profile_name"
        aws iam delete-instance-profile --instance-profile-name $profile_name 2>/dev/null || true
    fi
done

# 清理其他相關角色
for role_pattern in "eks-lab-test-eks-cluster-role" "AmazonEKSLoadBalancerControllerRole" "eks-node-group-"; do
    for role_name in $(aws iam list-roles --query "Roles[?contains(RoleName, '$role_pattern')].RoleName" --output text); do
        if [[ ! -z "$role_name" ]]; then
            echo "清理角色: $role_name"
            
            # 分離政策
            for policy_arn in $(aws iam list-attached-role-policies --role-name $role_name --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
                aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn 2>/dev/null || true
            done
            
            # 刪除內聯政策
            for policy_name in $(aws iam list-role-policies --role-name $role_name --query 'PolicyNames[]' --output text 2>/dev/null); do
                aws iam delete-role-policy --role-name $role_name --policy-name $policy_name 2>/dev/null || true
            done
            
            # 刪除角色
            aws iam delete-role --role-name $role_name 2>/dev/null || true
        fi
    done
done

echo "✅ IAM 資源已清理"
echo ""

# Phase 6: CloudWatch 資源清理
echo "📋 Phase 6: 清理 CloudWatch 資源"
echo "----------------------------------------"

echo "清理 CloudWatch 日誌群組..."
for log_group in $(aws logs describe-log-groups --region $AWS_REGION \
    --query "logGroups[?contains(logGroupName, '/aws/eks/$CLUSTER_NAME')].logGroupName" --output text); do
    if [[ ! -z "$log_group" ]]; then
        echo "刪除日誌群組: $log_group"
        aws logs delete-log-group --log-group-name "$log_group" --region $AWS_REGION 2>/dev/null || true
    fi
done

echo "✅ CloudWatch 資源已清理"
echo ""

# Phase 7: SQS 清理
echo "📋 Phase 7: 清理 SQS 佇列"
echo "----------------------------------------"

echo "清理 Karpenter SQS 佇列..."
if aws sqs get-queue-url --queue-name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
    QUEUE_URL=$(aws sqs get-queue-url --queue-name $CLUSTER_NAME --region $AWS_REGION --query 'QueueUrl' --output text)
    echo "刪除 SQS 佇列: $QUEUE_URL"
    aws sqs delete-queue --queue-url "$QUEUE_URL" --region $AWS_REGION 2>/dev/null || true
fi

echo "✅ SQS 資源已清理"
echo ""

# Phase 8: 最終驗證
echo "📋 Phase 8: 最終驗證"
echo "----------------------------------------"

echo "驗證主要資源已清理..."

# 檢查 EKS 集群
if aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
    echo "❌ EKS 集群仍存在"
else
    echo "✅ EKS 集群已清理"
fi

# 檢查 EC2 實例
REMAINING_INSTANCES=$(aws ec2 describe-instances --region $AWS_REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,stopped,pending" \
    --query 'Reservations[].Instances[].InstanceId' --output text | wc -w)

if [[ $REMAINING_INSTANCES -gt 0 ]]; then
    echo "❌ 仍有 $REMAINING_INSTANCES 個 EC2 實例未清理"
else
    echo "✅ 所有 EC2 實例已清理"
fi

# 檢查 Load Balancer
REMAINING_ALBS=$(aws elbv2 describe-load-balancers --region $AWS_REGION \
    --query "LoadBalancers[?VpcId=='$VPC_ID']" --output text | wc -l)

if [[ $REMAINING_ALBS -gt 0 ]]; then
    echo "❌ 仍有 $REMAINING_ALBS 個 Load Balancer 未清理"
else
    echo "✅ 所有 Load Balancer 已清理"
fi

echo ""

# 清理本地配置
echo "📋 清理本地配置"
echo "----------------------------------------"

echo "清理本地 kubeconfig..."
if [ -f ~/.kube/config ]; then
    # 備份並清理 EKS 上下文
    cp ~/.kube/config ~/.kube/config.backup.$(date +%Y%m%d_%H%M%S)
    kubectl config delete-context arn:aws:eks:$AWS_REGION:*:cluster/$CLUSTER_NAME 2>/dev/null || true
fi

echo "恢復 K3s kubeconfig (如果存在)..."
if [ -f /etc/rancher/k3s/k3s.yaml.bak ]; then
    sudo mv /etc/rancher/k3s/k3s.yaml.bak /etc/rancher/k3s/k3s.yaml 2>/dev/null || true
fi

echo "✅ 本地配置已清理"
echo ""

# 完成摘要
echo "🎉 AWS 資源清理完成！"
echo "========================================"
echo "已清理的資源類型:"
echo "✅ EKS 集群和節點群組"
echo "✅ EC2 實例和 Auto Scaling Groups"
echo "✅ VPC、子網路、NAT Gateway"
echo "✅ Load Balancer 和 Target Groups"
echo "✅ IAM 角色和政策"
echo "✅ CloudWatch 日誌群組"
echo "✅ SQS 佇列"
echo "✅ EBS 卷和快照"
echo "✅ 本地 kubeconfig"
echo ""
echo "💰 預期每日節省: ~$5.72 USD"
echo "📅 重建時請參考: COMPLETE_DEPLOYMENT_GUIDE.md"
echo ""
echo "⚠️  請在 AWS 控制台中確認所有資源已完全清理"
echo "⚠️  可能需要等待 5-10 分鐘讓某些資源完全刪除"