#!/bin/bash

# Complete Cleanup Script for EKS GitOps Infrastructure
# Author: jasontsai
# Repository: https://github.com/jasontsaicc/eks-terraform-karpenter

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
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

# Get AWS info
get_aws_info() {
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export AWS_REGION=${AWS_REGION:-ap-northeast-1}
    export CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
    
    log_info "AWS Account ID: $AWS_ACCOUNT_ID"
    log_info "AWS Region: $AWS_REGION"
    
    if [ -n "$CLUSTER_NAME" ]; then
        log_info "Cluster Name: $CLUSTER_NAME"
    else
        log_warn "Cluster name not found, some cleanup steps may be skipped"
    fi
}

# Step 1: Delete all Kubernetes resources
delete_k8s_resources() {
    log_step "Step 1: Deleting Kubernetes resources..."
    
    if [ -z "$CLUSTER_NAME" ]; then
        log_warn "No cluster found, skipping Kubernetes cleanup"
        return 0
    fi
    
    # Configure kubectl
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME 2>/dev/null || {
        log_warn "Cannot connect to cluster, it may already be deleted"
        return 0
    }
    
    # Delete applications in reverse order
    log_info "Deleting ArgoCD applications..."
    kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null || true
    
    log_info "Deleting GitLab resources..."
    helm uninstall gitlab -n gitlab --timeout=300s 2>/dev/null || true
    kubectl delete namespace gitlab --timeout=60s 2>/dev/null || true
    
    log_info "Deleting monitoring stack..."
    helm uninstall monitoring -n monitoring --timeout=60s 2>/dev/null || true
    kubectl delete namespace monitoring --timeout=60s 2>/dev/null || true
    
    log_info "Deleting ArgoCD..."
    helm uninstall argocd -n argocd --timeout=60s 2>/dev/null || true
    kubectl delete namespace argocd --timeout=60s 2>/dev/null || true
    
    log_info "Deleting Karpenter provisioners..."
    kubectl delete nodepools --all -n karpenter 2>/dev/null || true
    kubectl delete ec2nodeclasses --all -n karpenter 2>/dev/null || true
    
    log_info "Waiting for Karpenter nodes to terminate..."
    sleep 30
    
    log_info "Deleting Karpenter..."
    helm uninstall karpenter -n karpenter --timeout=60s 2>/dev/null || true
    kubectl delete namespace karpenter --timeout=60s 2>/dev/null || true
    
    log_info "Deleting AWS Load Balancer Controller..."
    helm uninstall aws-load-balancer-controller -n kube-system --timeout=60s 2>/dev/null || true
    
    log_info "Deleting cert-manager..."
    kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml 2>/dev/null || true
    
    log_info "Deleting all remaining ingresses..."
    kubectl delete ingress --all --all-namespaces 2>/dev/null || true
    
    log_info "Deleting all remaining services of type LoadBalancer..."
    kubectl delete svc --all --all-namespaces --field-selector spec.type=LoadBalancer 2>/dev/null || true
    
    log_info "Kubernetes resources deleted"
}

# Step 2: Delete AWS resources created by controllers
delete_aws_resources() {
    log_step "Step 2: Deleting AWS resources created by controllers..."
    
    # Delete ALBs
    log_info "Checking for Application Load Balancers..."
    local albs=$(aws elbv2 describe-load-balancers \
        --region $AWS_REGION \
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$albs" ]; then
        for alb in $albs; do
            log_info "Deleting ALB: $alb"
            aws elbv2 delete-load-balancer --load-balancer-arn $alb --region $AWS_REGION
        done
        sleep 30
    fi
    
    # Delete target groups
    log_info "Checking for target groups..."
    local tgs=$(aws elbv2 describe-target-groups \
        --region $AWS_REGION \
        --query "TargetGroups[?contains(TargetGroupName, 'k8s-')].TargetGroupArn" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$tgs" ]; then
        for tg in $tgs; do
            log_info "Deleting target group: $tg"
            aws elbv2 delete-target-group --target-group-arn $tg --region $AWS_REGION 2>/dev/null || true
        done
    fi
    
    # Delete security groups created by controllers
    log_info "Checking for controller-created security groups..."
    local sgs=$(aws ec2 describe-security-groups \
        --region $AWS_REGION \
        --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$sgs" ]; then
        for sg in $sgs; do
            log_info "Will delete security group: $sg (after EKS deletion)"
        done
    fi
    
    log_info "AWS resources cleanup prepared"
}

# Step 3: Destroy EKS infrastructure
destroy_eks() {
    log_step "Step 3: Destroying EKS infrastructure..."
    
    # Check if terraform state exists
    if [ ! -f "terraform.tfstate" ] && [ ! -f "terraform-backend/terraform.tfstate" ]; then
        log_warn "No Terraform state found, skipping EKS destruction"
        return 0
    fi
    
    # Destroy EKS and related resources
    log_info "Running Terraform destroy..."
    terraform destroy -auto-approve -var="region=$AWS_REGION"
    
    log_info "EKS infrastructure destroyed"
}

# Step 4: Cleanup remaining AWS resources
cleanup_remaining_resources() {
    log_step "Step 4: Cleaning up remaining AWS resources..."
    
    # Delete VPC endpoints
    log_info "Checking for VPC endpoints..."
    local vpc_id=$(aws ec2 describe-vpcs \
        --region $AWS_REGION \
        --filters "Name=tag:Project,Values=eks-test" \
        --query "Vpcs[0].VpcId" \
        --output text 2>/dev/null || echo "")
    
    if [ "$vpc_id" != "None" ] && [ -n "$vpc_id" ]; then
        local endpoints=$(aws ec2 describe-vpc-endpoints \
            --region $AWS_REGION \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query "VpcEndpoints[].VpcEndpointId" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$endpoints" ]; then
            for endpoint in $endpoints; do
                log_info "Deleting VPC endpoint: $endpoint"
                aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint --region $AWS_REGION 2>/dev/null || true
            done
        fi
    fi
    
    # Delete CloudWatch log groups
    log_info "Checking for CloudWatch log groups..."
    local log_groups=$(aws logs describe-log-groups \
        --region $AWS_REGION \
        --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
        --query "logGroups[].logGroupName" \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$log_groups" ]; then
        for lg in $log_groups; do
            log_info "Deleting log group: $lg"
            aws logs delete-log-group --log-group-name "$lg" --region $AWS_REGION 2>/dev/null || true
        done
    fi
    
    log_info "Remaining resources cleaned up"
}

# Step 5: Destroy Terraform backend
destroy_backend() {
    log_step "Step 5: Destroying Terraform backend..."
    
    read -p "Do you want to destroy the Terraform backend? This will delete all state files! (yes/no): " destroy_backend_choice
    
    if [ "$destroy_backend_choice" != "yes" ]; then
        log_info "Keeping Terraform backend"
        return 0
    fi
    
    if [ ! -f "terraform-backend/terraform.tfstate" ]; then
        log_warn "No backend state found, skipping"
        return 0
    fi
    
    cd terraform-backend
    
    # Get bucket name before destroying
    local bucket_name=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    
    if [ -n "$bucket_name" ]; then
        log_info "Emptying S3 bucket: $bucket_name"
        aws s3 rm s3://$bucket_name --recursive --region $AWS_REGION 2>/dev/null || true
    fi
    
    # Destroy backend infrastructure
    terraform destroy -auto-approve
    
    cd ..
    
    log_info "Terraform backend destroyed"
}

# Step 6: Final cleanup
final_cleanup() {
    log_step "Step 6: Final cleanup..."
    
    # Remove local files
    log_info "Removing local state files..."
    rm -f terraform.tfstate*
    rm -f terraform-backend/terraform.tfstate*
    rm -f *.tfplan
    rm -f backend-config.txt
    rm -rf .terraform/
    rm -rf terraform-backend/.terraform/
    
    # Remove kubeconfig entry
    if [ -n "$CLUSTER_NAME" ]; then
        log_info "Removing kubeconfig entry..."
        kubectl config delete-cluster $CLUSTER_NAME 2>/dev/null || true
        kubectl config delete-context $CLUSTER_NAME 2>/dev/null || true
        kubectl config delete-user $CLUSTER_NAME 2>/dev/null || true
    fi
    
    log_info "Final cleanup complete"
}

# Verification
verify_cleanup() {
    log_step "Verifying cleanup..."
    
    echo ""
    echo "==================================================="
    echo "Cleanup Verification"
    echo "==================================================="
    
    # Check for remaining EKS clusters
    local clusters=$(aws eks list-clusters --region $AWS_REGION --query "clusters[?contains(@, 'eks-test')]" --output text 2>/dev/null || echo "")
    if [ -n "$clusters" ]; then
        log_warn "Remaining EKS clusters found: $clusters"
    else
        log_info "No EKS clusters found ✓"
    fi
    
    # Check for remaining load balancers
    local albs=$(aws elbv2 describe-load-balancers --region $AWS_REGION --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-')]" --output text 2>/dev/null || echo "")
    if [ -n "$albs" ]; then
        log_warn "Remaining load balancers found"
    else
        log_info "No load balancers found ✓"
    fi
    
    # Estimate remaining costs
    echo ""
    log_info "Estimated remaining monthly costs:"
    echo "- NAT Gateways: Check manually"
    echo "- EBS Volumes: Check manually"
    echo "- Elastic IPs: Check manually"
    echo ""
    echo "Run 'aws ce get-cost-and-usage' to check actual costs"
    
    log_info "Cleanup verification complete"
}

# Main execution
main() {
    log_warn "WARNING: This will delete ALL resources created by this project!"
    echo "This includes:"
    echo "- EKS cluster and all nodes"
    echo "- All Kubernetes applications and data"
    echo "- VPC and networking resources"
    echo "- Load balancers and target groups"
    echo "- IAM roles and policies"
    echo "- Terraform state (if confirmed)"
    echo ""
    
    read -p "Are you sure you want to continue? Type 'yes' to confirm: " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
    
    log_info "Starting complete cleanup..."
    echo "=============================================="
    
    # Get AWS info
    get_aws_info
    
    # Execute cleanup steps
    delete_k8s_resources
    delete_aws_resources
    destroy_eks
    cleanup_remaining_resources
    destroy_backend
    final_cleanup
    verify_cleanup
    
    echo ""
    echo "=============================================="
    log_info "Cleanup completed!"
    echo ""
    log_warn "Please manually check AWS console for any remaining resources"
    echo "Especially check for:"
    echo "- Orphaned EBS volumes"
    echo "- Unused Elastic IPs"
    echo "- CloudWatch log groups"
    echo "- S3 buckets"
}

# Run main function
main "$@"