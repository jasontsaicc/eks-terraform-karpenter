#!/bin/bash

# AWS EKS 強制清理腳本 - 確保完全清除所有 AWS 資源
# 此腳本會強制刪除所有相關資源，包括 VPC、NAT Gateway、ELB 等

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

# 確保必要的工具存在
check_requirements() {
    log_info "檢查必要工具..."
    
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI 未安裝"
        exit 1
    fi
    
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform 未安裝"
        exit 1
    fi
    
    # 檢查 AWS 認證
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS 認證失敗，請設定 AWS credentials"
        exit 1
    fi
    
    log_info "✓ 所有必要工具已就緒"
}

# 獲取集群資訊
get_cluster_info() {
    log_info "獲取集群資訊..."
    
    # 嘗試從 Terraform 輸出獲取
    CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
    
    if [ -z "$CLUSTER_NAME" ]; then
        # 嘗試從 terraform.tfvars 獲取
        if [ -f "terraform.tfvars" ]; then
            CLUSTER_NAME=$(grep cluster_name terraform.tfvars 2>/dev/null | cut -d'"' -f2 || echo "")
        fi
    fi
    
    if [ -z "$CLUSTER_NAME" ]; then
        # 嘗試列出所有 EKS 集群
        log_warn "無法自動獲取集群名稱，列出所有 EKS 集群："
        aws eks list-clusters --query 'clusters[]' --output table
        read -p "請輸入要清理的集群名稱（或輸入 'NONE' 跳過 EKS 清理）: " CLUSTER_NAME
    fi
    
    if [ "$CLUSTER_NAME" != "NONE" ] && [ ! -z "$CLUSTER_NAME" ]; then
        log_info "目標集群: $CLUSTER_NAME"
        
        # 獲取 VPC ID
        VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
        if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
            log_info "VPC ID: $VPC_ID"
        fi
    fi
}

# 清理 Load Balancers
cleanup_load_balancers() {
    log_step "清理 Load Balancers..."
    
    # 清理 ELBv2 (ALB/NLB)
    if [ ! -z "$CLUSTER_NAME" ]; then
        # 獲取所有標記為集群的 Load Balancers
        LB_ARNS=$(aws elbv2 describe-load-balancers \
            --query "LoadBalancers[?contains(LoadBalancerArn, '$CLUSTER_NAME')].LoadBalancerArn" \
            --output text)
        
        # 同時檢查標籤
        ALL_LBS=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text)
        
        for lb_arn in $ALL_LBS; do
            TAGS=$(aws elbv2 describe-tags --resource-arns $lb_arn \
                --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME'].Value" \
                --output text 2>/dev/null || echo "")
            
            if [ ! -z "$TAGS" ]; then
                LB_ARNS="$LB_ARNS $lb_arn"
            fi
        done
        
        for lb_arn in $LB_ARNS; do
            if [ ! -z "$lb_arn" ]; then
                log_info "刪除 Load Balancer: $lb_arn"
                aws elbv2 delete-load-balancer --load-balancer-arn $lb_arn || true
            fi
        done
    fi
    
    # 清理 Classic ELB
    CLASSIC_ELBS=$(aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text)
    
    for elb_name in $CLASSIC_ELBS; do
        TAGS=$(aws elb describe-tags --load-balancer-names $elb_name \
            --query "TagDescriptions[].Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME'].Value" \
            --output text 2>/dev/null || echo "")
        
        if [ ! -z "$TAGS" ]; then
            log_info "刪除 Classic ELB: $elb_name"
            aws elb delete-load-balancer --load-balancer-name $elb_name || true
        fi
    done
    
    # 等待 Load Balancer 刪除
    sleep 10
}

# 清理 Target Groups
cleanup_target_groups() {
    log_step "清理 Target Groups..."
    
    if [ ! -z "$VPC_ID" ]; then
        TARGET_GROUPS=$(aws elbv2 describe-target-groups \
            --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
            --output text)
        
        for tg_arn in $TARGET_GROUPS; do
            if [ ! -z "$tg_arn" ]; then
                log_info "刪除 Target Group: $tg_arn"
                aws elbv2 delete-target-group --target-group-arn $tg_arn || true
            fi
        done
    fi
}

# 清理 EC2 實例
cleanup_ec2_instances() {
    log_step "強制清理所有相關 EC2 實例..."
    
    # 清理 Karpenter 創建的實例
    if [ ! -z "$CLUSTER_NAME" ]; then
        INSTANCE_IDS=$(aws ec2 describe-instances \
            --filters "Name=tag:karpenter.sh/cluster,Values=$CLUSTER_NAME" \
                      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query 'Reservations[].Instances[].InstanceId' \
            --output text)
        
        if [ ! -z "$INSTANCE_IDS" ]; then
            log_info "終止 Karpenter 實例: $INSTANCE_IDS"
            aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
            aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS || true
        fi
    fi
    
    # 清理 EKS 節點組實例
    if [ ! -z "$CLUSTER_NAME" ]; then
        INSTANCE_IDS=$(aws ec2 describe-instances \
            --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
                      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query 'Reservations[].Instances[].InstanceId' \
            --output text)
        
        if [ ! -z "$INSTANCE_IDS" ]; then
            log_info "終止 EKS 節點組實例: $INSTANCE_IDS"
            aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
            aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS || true
        fi
    fi
}

# 清理 Launch Templates
cleanup_launch_templates() {
    log_step "清理 Launch Templates..."
    
    if [ ! -z "$CLUSTER_NAME" ]; then
        # Karpenter Launch Templates
        LAUNCH_TEMPLATES=$(aws ec2 describe-launch-templates \
            --filters "Name=tag:karpenter.sh/cluster,Values=$CLUSTER_NAME" \
            --query 'LaunchTemplates[].LaunchTemplateId' \
            --output text)
        
        for lt_id in $LAUNCH_TEMPLATES; do
            if [ ! -z "$lt_id" ]; then
                log_info "刪除 Launch Template: $lt_id"
                aws ec2 delete-launch-template --launch-template-id $lt_id || true
            fi
        done
    fi
}

# 清理 Auto Scaling Groups
cleanup_auto_scaling_groups() {
    log_step "清理 Auto Scaling Groups..."
    
    if [ ! -z "$CLUSTER_NAME" ]; then
        ASG_NAMES=$(aws autoscaling describe-auto-scaling-groups \
            --query "AutoScalingGroups[?contains(AutoScalingGroupName, '$CLUSTER_NAME')].AutoScalingGroupName" \
            --output text)
        
        for asg_name in $ASG_NAMES; do
            if [ ! -z "$asg_name" ]; then
                log_info "刪除 Auto Scaling Group: $asg_name"
                aws autoscaling update-auto-scaling-group \
                    --auto-scaling-group-name $asg_name \
                    --min-size 0 --desired-capacity 0 || true
                
                aws autoscaling delete-auto-scaling-group \
                    --auto-scaling-group-name $asg_name \
                    --force-delete || true
            fi
        done
    fi
}

# 清理 EKS 集群
cleanup_eks_cluster() {
    log_step "清理 EKS 集群..."
    
    if [ -z "$CLUSTER_NAME" ] || [ "$CLUSTER_NAME" == "NONE" ]; then
        log_warn "跳過 EKS 集群清理"
        return
    fi
    
    # 檢查集群是否存在
    if ! aws eks describe-cluster --name $CLUSTER_NAME &> /dev/null; then
        log_info "EKS 集群不存在或已刪除: $CLUSTER_NAME"
        return
    fi
    
    # 刪除節點組
    NODEGROUPS=$(aws eks list-nodegroups --cluster-name $CLUSTER_NAME --query 'nodegroups[]' --output text 2>/dev/null || echo "")
    
    for ng in $NODEGROUPS; do
        if [ ! -z "$ng" ]; then
            log_info "刪除節點組: $ng"
            aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $ng || true
        fi
    done
    
    # 等待節點組刪除
    for ng in $NODEGROUPS; do
        if [ ! -z "$ng" ]; then
            log_info "等待節點組刪除: $ng"
            aws eks wait nodegroup-deleted --cluster-name $CLUSTER_NAME --nodegroup-name $ng 2>/dev/null || true
        fi
    done
    
    # 刪除 Fargate profiles
    FARGATE_PROFILES=$(aws eks list-fargate-profiles --cluster-name $CLUSTER_NAME --query 'fargateProfileNames[]' --output text 2>/dev/null || echo "")
    
    for fp in $FARGATE_PROFILES; do
        if [ ! -z "$fp" ]; then
            log_info "刪除 Fargate profile: $fp"
            aws eks delete-fargate-profile --cluster-name $CLUSTER_NAME --fargate-profile-name $fp || true
        fi
    done
    
    # 刪除集群
    log_info "刪除 EKS 集群: $CLUSTER_NAME"
    aws eks delete-cluster --name $CLUSTER_NAME || true
    
    # 等待集群刪除
    log_info "等待 EKS 集群刪除..."
    aws eks wait cluster-deleted --name $CLUSTER_NAME 2>/dev/null || true
}

# 清理 VPC 資源
cleanup_vpc_resources() {
    log_step "強制清理 VPC 資源..."
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        # 嘗試通過標籤查找 VPC
        if [ ! -z "$CLUSTER_NAME" ]; then
            VPC_ID=$(aws ec2 describe-vpcs \
                --filters "Name=tag:Name,Values=*$CLUSTER_NAME*" \
                --query 'Vpcs[0].VpcId' \
                --output text 2>/dev/null || echo "")
        fi
    fi
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        log_warn "無法找到 VPC，跳過 VPC 清理"
        return
    fi
    
    log_info "清理 VPC: $VPC_ID"
    
    # 1. 刪除 NAT Gateways
    log_info "刪除 NAT Gateways..."
    NAT_GATEWAYS=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
        --query 'NatGateways[].NatGatewayId' \
        --output text)
    
    for nat_id in $NAT_GATEWAYS; do
        if [ ! -z "$nat_id" ]; then
            log_info "刪除 NAT Gateway: $nat_id"
            aws ec2 delete-nat-gateway --nat-gateway-id $nat_id || true
        fi
    done
    
    # 等待 NAT Gateway 刪除
    for nat_id in $NAT_GATEWAYS; do
        if [ ! -z "$nat_id" ]; then
            log_info "等待 NAT Gateway 刪除: $nat_id"
            while true; do
                STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids $nat_id --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
                if [ "$STATE" == "deleted" ] || [ "$STATE" == "None" ]; then
                    break
                fi
                sleep 10
            done
        fi
    done
    
    # 2. 釋放 Elastic IPs
    log_info "釋放 Elastic IPs..."
    ALLOCATION_IDS=$(aws ec2 describe-addresses \
        --filters "Name=tag:Name,Values=*$CLUSTER_NAME*" \
        --query 'Addresses[].AllocationId' \
        --output text)
    
    for alloc_id in $ALLOCATION_IDS; do
        if [ ! -z "$alloc_id" ]; then
            log_info "釋放 Elastic IP: $alloc_id"
            aws ec2 release-address --allocation-id $alloc_id || true
        fi
    done
    
    # 3. 刪除 VPC Endpoints
    log_info "刪除 VPC Endpoints..."
    VPC_ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'VpcEndpoints[].VpcEndpointId' \
        --output text)
    
    for endpoint_id in $VPC_ENDPOINTS; do
        if [ ! -z "$endpoint_id" ]; then
            log_info "刪除 VPC Endpoint: $endpoint_id"
            aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint_id || true
        fi
    done
    
    # 4. 刪除安全組（除了默認安全組）
    log_info "刪除安全組..."
    SECURITY_GROUPS=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text)
    
    # 首先刪除所有安全組規則
    for sg_id in $SECURITY_GROUPS; do
        if [ ! -z "$sg_id" ]; then
            log_info "清理安全組規則: $sg_id"
            # 刪除入站規則
            aws ec2 revoke-security-group-ingress --group-id $sg_id \
                --ip-permissions "$(aws ec2 describe-security-groups --group-ids $sg_id --query 'SecurityGroups[0].IpPermissions')" 2>/dev/null || true
            # 刪除出站規則
            aws ec2 revoke-security-group-egress --group-id $sg_id \
                --ip-permissions "$(aws ec2 describe-security-groups --group-ids $sg_id --query 'SecurityGroups[0].IpPermissionsEgress')" 2>/dev/null || true
        fi
    done
    
    # 然後刪除安全組
    for sg_id in $SECURITY_GROUPS; do
        if [ ! -z "$sg_id" ]; then
            log_info "刪除安全組: $sg_id"
            aws ec2 delete-security-group --group-id $sg_id || true
        fi
    done
    
    # 5. 刪除網路介面
    log_info "刪除網路介面..."
    NETWORK_INTERFACES=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' \
        --output text)
    
    for eni_id in $NETWORK_INTERFACES; do
        if [ ! -z "$eni_id" ]; then
            # 先嘗試 detach
            ATTACHMENT_ID=$(aws ec2 describe-network-interfaces \
                --network-interface-ids $eni_id \
                --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
                --output text 2>/dev/null || echo "")
            
            if [ ! -z "$ATTACHMENT_ID" ] && [ "$ATTACHMENT_ID" != "None" ]; then
                log_info "Detaching 網路介面: $eni_id"
                aws ec2 detach-network-interface --attachment-id $ATTACHMENT_ID --force || true
                sleep 5
            fi
            
            log_info "刪除網路介面: $eni_id"
            aws ec2 delete-network-interface --network-interface-id $eni_id || true
        fi
    done
    
    # 6. 刪除子網路
    log_info "刪除子網路..."
    SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[].SubnetId' \
        --output text)
    
    for subnet_id in $SUBNETS; do
        if [ ! -z "$subnet_id" ]; then
            log_info "刪除子網路: $subnet_id"
            aws ec2 delete-subnet --subnet-id $subnet_id || true
        fi
    done
    
    # 7. 刪除路由表
    log_info "刪除路由表..."
    ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
        --output text)
    
    for rt_id in $ROUTE_TABLES; do
        if [ ! -z "$rt_id" ]; then
            # 先刪除路由
            aws ec2 describe-route-tables --route-table-ids $rt_id \
                --query 'RouteTables[0].Routes[?GatewayId!=`local`].[DestinationCidrBlock]' \
                --output text | while read cidr; do
                if [ ! -z "$cidr" ]; then
                    aws ec2 delete-route --route-table-id $rt_id --destination-cidr-block $cidr || true
                fi
            done
            
            log_info "刪除路由表: $rt_id"
            aws ec2 delete-route-table --route-table-id $rt_id || true
        fi
    done
    
    # 8. Detach 和刪除 Internet Gateway
    log_info "刪除 Internet Gateway..."
    IGW_ID=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text)
    
    if [ ! -z "$IGW_ID" ] && [ "$IGW_ID" != "None" ]; then
        log_info "Detach Internet Gateway: $IGW_ID"
        aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID || true
        
        log_info "刪除 Internet Gateway: $IGW_ID"
        aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID || true
    fi
    
    # 9. 刪除 VPC
    log_info "刪除 VPC: $VPC_ID"
    aws ec2 delete-vpc --vpc-id $VPC_ID || true
}

# 清理 IAM 資源
cleanup_iam_resources() {
    log_step "清理 IAM 資源..."
    
    if [ -z "$CLUSTER_NAME" ]; then
        log_warn "無集群名稱，跳過 IAM 清理"
        return
    fi
    
    # 清理 OIDC Provider
    OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || echo "")
    
    if [ ! -z "$OIDC_URL" ] && [ "$OIDC_URL" != "None" ]; then
        OIDC_ID=$(echo $OIDC_URL | sed 's/.*\///')
        OIDC_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/oidc.eks.$(aws configure get region).amazonaws.com/id/$OIDC_ID"
        
        log_info "刪除 OIDC Provider: $OIDC_ARN"
        aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $OIDC_ARN 2>/dev/null || true
    fi
    
    # 清理 IAM 角色
    IAM_ROLES=(
        "KarpenterControllerRole-$CLUSTER_NAME"
        "KarpenterNodeRole-$CLUSTER_NAME"
        "aws-load-balancer-controller-$CLUSTER_NAME"
        "eks-cluster-role-$CLUSTER_NAME"
        "eks-node-group-role-$CLUSTER_NAME"
    )
    
    for role_name in "${IAM_ROLES[@]}"; do
        if aws iam get-role --role-name $role_name &> /dev/null; then
            log_info "清理 IAM 角色: $role_name"
            
            # 先分離所有策略
            ATTACHED_POLICIES=$(aws iam list-attached-role-policies --role-name $role_name --query 'AttachedPolicies[].PolicyArn' --output text)
            for policy_arn in $ATTACHED_POLICIES; do
                aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn || true
            done
            
            # 刪除內聯策略
            INLINE_POLICIES=$(aws iam list-role-policies --role-name $role_name --query 'PolicyNames[]' --output text)
            for policy_name in $INLINE_POLICIES; do
                aws iam delete-role-policy --role-name $role_name --policy-name $policy_name || true
            done
            
            # 刪除實例配置文件（如果有）
            INSTANCE_PROFILES=$(aws iam list-instance-profiles-for-role --role-name $role_name --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || echo "")
            for profile_name in $INSTANCE_PROFILES; do
                aws iam remove-role-from-instance-profile --instance-profile-name $profile_name --role-name $role_name || true
                aws iam delete-instance-profile --instance-profile-name $profile_name || true
            done
            
            # 刪除角色
            aws iam delete-role --role-name $role_name || true
        fi
    done
}

# 清理 S3 儲存桶
cleanup_s3_buckets() {
    log_step "清理 S3 儲存桶..."
    
    if [ ! -z "$CLUSTER_NAME" ]; then
        # 查找可能相關的 S3 儲存桶
        S3_BUCKETS=$(aws s3api list-buckets --query "Buckets[?contains(Name, '$CLUSTER_NAME')].Name" --output text)
        
        for bucket in $S3_BUCKETS; do
            log_warn "發現可能相關的 S3 儲存桶: $bucket"
            read -p "是否刪除此儲存桶？(yes/no): " confirm
            
            if [ "$confirm" == "yes" ]; then
                log_info "清空並刪除 S3 儲存桶: $bucket"
                aws s3 rm s3://$bucket --recursive || true
                aws s3api delete-bucket --bucket $bucket || true
            fi
        done
    fi
}

# 使用 Terraform 清理剩餘資源
cleanup_with_terraform() {
    log_step "使用 Terraform 清理剩餘資源..."
    
    if [ ! -f "main.tf" ]; then
        log_warn "未找到 Terraform 配置，跳過 Terraform 清理"
        return
    fi
    
    # 初始化 Terraform
    log_info "初始化 Terraform..."
    if [ -f "backend-config.txt" ]; then
        terraform init -backend-config=backend-config.txt -upgrade
    else
        terraform init -upgrade
    fi
    
    # 刷新狀態
    log_info "刷新 Terraform 狀態..."
    terraform refresh || true
    
    # 嘗試銷毀
    log_info "執行 Terraform destroy..."
    terraform destroy -auto-approve || true
    
    # 如果失敗，嘗試逐個刪除資源
    RESOURCES=$(terraform state list 2>/dev/null || echo "")
    
    for resource in $RESOURCES; do
        log_info "嘗試刪除 Terraform 資源: $resource"
        terraform destroy -target=$resource -auto-approve || true
    done
    
    # 清理狀態文件
    log_info "清理 Terraform 狀態..."
    rm -f terraform.tfstate*
    rm -f .terraform.lock.hcl
    rm -rf .terraform/
}

# 最終驗證
final_verification() {
    log_step "執行最終驗證..."
    
    local has_issues=false
    
    # 檢查 EKS 集群
    if [ ! -z "$CLUSTER_NAME" ] && [ "$CLUSTER_NAME" != "NONE" ]; then
        if aws eks describe-cluster --name $CLUSTER_NAME &> /dev/null; then
            log_error "❌ EKS 集群仍存在: $CLUSTER_NAME"
            has_issues=true
        else
            log_info "✓ EKS 集群已刪除"
        fi
    fi
    
    # 檢查 VPC
    if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
        if aws ec2 describe-vpcs --vpc-ids $VPC_ID &> /dev/null; then
            log_error "❌ VPC 仍存在: $VPC_ID"
            has_issues=true
        else
            log_info "✓ VPC 已刪除"
        fi
    fi
    
    # 檢查 NAT Gateways
    if [ ! -z "$VPC_ID" ]; then
        NAT_COUNT=$(aws ec2 describe-nat-gateways \
            --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
            --query 'NatGateways | length' \
            --output text 2>/dev/null || echo "0")
        
        if [ "$NAT_COUNT" -gt 0 ]; then
            log_error "❌ 仍有 $NAT_COUNT 個 NAT Gateway 未刪除"
            has_issues=true
        else
            log_info "✓ 所有 NAT Gateways 已刪除"
        fi
    fi
    
    # 檢查 Load Balancers
    if [ ! -z "$CLUSTER_NAME" ]; then
        LB_COUNT=$(aws elbv2 describe-load-balancers \
            --query "LoadBalancers[?contains(LoadBalancerName, '$CLUSTER_NAME')] | length" \
            --output text 2>/dev/null || echo "0")
        
        if [ "$LB_COUNT" -gt 0 ]; then
            log_error "❌ 仍有 $LB_COUNT 個 Load Balancer 未刪除"
            has_issues=true
        else
            log_info "✓ 所有 Load Balancers 已刪除"
        fi
    fi
    
    if [ "$has_issues" = true ]; then
        log_warn "清理未完全成功，請手動檢查 AWS Console"
    else
        log_info "✅ 所有資源已成功清理！"
    fi
}

# 主函數
main() {
    log_info "開始 AWS EKS 強制清理流程..."
    
    # 確認操作
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}⚠️  警告：此腳本將強制刪除所有 AWS 資源！${NC}"
    echo -e "${RED}包括：EKS、VPC、NAT Gateway、Load Balancer、EC2 等${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    read -p "確定要繼續嗎？輸入 'YES' 確認: " confirm
    
    if [ "$confirm" != "YES" ]; then
        log_info "清理已取消"
        exit 0
    fi
    
    # 執行清理步驟
    check_requirements
    get_cluster_info
    
    # 先清理依賴資源
    cleanup_load_balancers
    cleanup_target_groups
    cleanup_ec2_instances
    cleanup_launch_templates
    cleanup_auto_scaling_groups
    
    # 清理 EKS
    cleanup_eks_cluster
    
    # 清理網路資源
    cleanup_vpc_resources
    
    # 清理 IAM
    cleanup_iam_resources
    
    # 清理 S3
    cleanup_s3_buckets
    
    # 嘗試使用 Terraform 清理
    cleanup_with_terraform
    
    # 最終驗證
    final_verification
    
    log_info "清理流程完成！"
    log_info "請登入 AWS Console 確認所有收費資源已被清除。"
}

# 執行主函數
main "$@"