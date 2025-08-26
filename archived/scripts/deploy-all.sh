#!/bin/bash

# Complete Deployment Script for EKS GitOps Infrastructure
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

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check required tools
    local tools=("terraform" "kubectl" "helm" "aws" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            log_error "$tool is not installed"
            exit 1
        fi
    done
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured"
        exit 1
    fi
    
    log_info "All prerequisites met"
}

# Get AWS account information
get_aws_info() {
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    export AWS_REGION=${AWS_REGION:-ap-northeast-1}
    log_info "AWS Account ID: $AWS_ACCOUNT_ID"
    log_info "AWS Region: $AWS_REGION"
}

# Step 1: Deploy Terraform Backend
deploy_backend() {
    log_step "Step 1: Deploying Terraform backend..."
    
    if [ -f "terraform-backend/terraform.tfstate" ]; then
        log_warn "Backend already exists, skipping..."
        return 0
    fi
    
    cd terraform-backend
    terraform init
    terraform plan -out=backend.tfplan
    terraform apply backend.tfplan
    rm -f backend.tfplan
    cd ..
    
    log_info "Backend deployed successfully"
}

# Step 2: Deploy EKS Infrastructure
deploy_eks() {
    log_step "Step 2: Deploying EKS infrastructure..."
    
    # Initialize Terraform with backend
    terraform init
    
    # Plan deployment
    terraform plan -var="region=$AWS_REGION" -out=eks.tfplan
    
    # Apply deployment
    terraform apply eks.tfplan
    rm -f eks.tfplan
    
    # Get outputs
    export CLUSTER_NAME=$(terraform output -raw cluster_name)
    export VPC_ID=$(terraform output -raw vpc_id)
    export CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
    export AWS_LOAD_BALANCER_CONTROLLER_ROLE_ARN=$(terraform output -raw aws_load_balancer_controller_role_arn 2>/dev/null || echo "")
    export KARPENTER_CONTROLLER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn 2>/dev/null || echo "")
    
    log_info "EKS cluster deployed: $CLUSTER_NAME"
}

# Step 3: Configure kubectl
configure_kubectl() {
    log_step "Step 3: Configuring kubectl..."
    
    aws eks update-kubeconfig \
        --region $AWS_REGION \
        --name $CLUSTER_NAME \
        --alias $CLUSTER_NAME
    
    # Verify connection
    kubectl get nodes
    
    log_info "kubectl configured successfully"
}

# Step 4: Install AWS Load Balancer Controller
install_alb_controller() {
    log_step "Step 4: Installing AWS Load Balancer Controller..."
    
    # Install cert-manager (required for webhook)
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
    
    # Wait for cert-manager to be ready
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/component=webhook \
        -n cert-manager \
        --timeout=120s
    
    # Add helm repo
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    # Install AWS Load Balancer Controller
    helm upgrade --install aws-load-balancer-controller \
        eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName=$CLUSTER_NAME \
        --set serviceAccount.create=true \
        --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$AWS_LOAD_BALANCER_CONTROLLER_ROLE_ARN \
        --set region=$AWS_REGION \
        --set vpcId=$VPC_ID \
        --wait
    
    log_info "AWS Load Balancer Controller installed"
}

# Step 5: Install Karpenter
install_karpenter() {
    log_step "Step 5: Installing Karpenter..."
    
    # Create namespace
    kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -
    
    # Add helm repo
    helm repo add karpenter https://karpenter.sh/charts
    helm repo update
    
    # Install Karpenter
    helm upgrade --install karpenter \
        oci://public.ecr.aws/karpenter/karpenter \
        --namespace kube-system \
        --version "1.0.6" \
        --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_CONTROLLER_ROLE_ARN \
        --set settings.clusterName=$CLUSTER_NAME \
        --set settings.interruptionQueue=$CLUSTER_NAME-karpenter \
        --wait
    
    # Apply NodePool configuration
    kubectl apply -f /home/ubuntu/projects/aws_eks_terraform/karpenter-nodepool.yaml
    
    log_info "Karpenter installed and configured"
}

# Step 6: Install ArgoCD
install_argocd() {
    log_step "Step 6: Installing ArgoCD..."
    
    # Create namespace
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    
    # Add helm repo
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    
    # Install ArgoCD
    helm upgrade --install argocd \
        argo/argo-cd \
        --namespace argocd \
        --version 5.51.6 \
        -f argocd/values.yaml \
        --wait
    
    # Apply platform applications
    kubectl apply -f gitops-apps/platform-apps.yaml
    
    # Get initial admin password
    local ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    
    log_info "ArgoCD installed"
    log_warn "ArgoCD admin password: $ARGOCD_PASSWORD"
    log_warn "Please change this password immediately!"
}

# Step 7: Install GitLab (Optional)
install_gitlab() {
    log_step "Step 7: Installing GitLab (Optional)..."
    
    read -p "Do you want to install GitLab? (yes/no): " install_gitlab_choice
    
    if [ "$install_gitlab_choice" != "yes" ]; then
        log_info "Skipping GitLab installation"
        return 0
    fi
    
    # Create namespace
    kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -
    
    # Add helm repo
    helm repo add gitlab https://charts.gitlab.io
    helm repo update
    
    # Install GitLab
    helm upgrade --install gitlab \
        gitlab/gitlab \
        --namespace gitlab \
        --version 7.11.0 \
        -f gitlab/values.yaml \
        --timeout 600s \
        --wait
    
    log_info "GitLab installed"
}

# Step 8: Setup Monitoring
setup_monitoring() {
    log_step "Step 8: Setting up monitoring..."
    
    # Create namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Add helm repo
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    # Install kube-prometheus-stack
    helm upgrade --install monitoring \
        prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --version 58.7.2 \
        --set prometheus.prometheusSpec.retention=30d \
        --set grafana.adminPassword=changeme \
        --wait
    
    log_info "Monitoring stack installed"
}

# Step 9: Configure DNS and SSL
configure_dns_ssl() {
    log_step "Step 9: Configuring DNS and SSL..."
    
    log_warn "Manual steps required:"
    echo "1. Create ACM certificates for your domains in AWS Certificate Manager"
    echo "2. Update the certificate ARNs in the Ingress annotations"
    echo "3. Configure Route53 or your DNS provider to point to the ALB"
    echo ""
    
    # Get ALB URL
    local ALB_URL=$(kubectl get ingress -A -o json | jq -r '.items[0].status.loadBalancer.ingress[0].hostname' 2>/dev/null || echo "Not yet available")
    
    if [ "$ALB_URL" != "Not yet available" ]; then
        log_info "ALB URL: $ALB_URL"
        echo "Configure your DNS to point to: $ALB_URL"
    else
        log_warn "ALB not yet provisioned. Check later with: kubectl get ingress -A"
    fi
}

# Step 10: Final verification
verify_deployment() {
    log_step "Step 10: Verifying deployment..."
    
    echo ""
    echo "==================================================="
    echo "Deployment Summary"
    echo "==================================================="
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Region: $AWS_REGION"
    echo "VPC ID: $VPC_ID"
    echo ""
    
    # Check nodes
    echo "Nodes:"
    kubectl get nodes
    echo ""
    
    # Check key components
    echo "Key Components Status:"
    kubectl get pods -n kube-system | grep aws-load-balancer-controller || echo "ALB Controller: Not found"
    kubectl get pods -n karpenter || echo "Karpenter: Not found"
    kubectl get pods -n argocd || echo "ArgoCD: Not found"
    kubectl get pods -n monitoring || echo "Monitoring: Not found"
    echo ""
    
    # Get service URLs
    echo "Service URLs:"
    echo "ArgoCD: kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "Grafana: kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80"
    echo ""
    
    log_info "Deployment verification complete"
}

# Cleanup function
cleanup() {
    log_warn "Cleaning up temporary files..."
    rm -f *.tfplan
    rm -f backend-config.txt
}

# Main execution
main() {
    log_info "Starting EKS GitOps Infrastructure Deployment"
    echo "=============================================="
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Execute steps
    check_prerequisites
    get_aws_info
    
    # Core infrastructure
    deploy_backend
    deploy_eks
    configure_kubectl
    
    # Platform components
    install_alb_controller
    install_karpenter
    install_argocd
    
    # Optional components
    install_gitlab
    setup_monitoring
    
    # Final steps
    configure_dns_ssl
    verify_deployment
    
    echo ""
    echo "=============================================="
    log_info "Deployment completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Access ArgoCD UI and change the admin password"
    echo "2. Configure DNS records for your services"
    echo "3. Apply your application manifests"
    echo "4. Monitor the cluster using Grafana"
    echo ""
    echo "To destroy everything: ./scripts/cleanup-all.sh"
}

# Run main function
main "$@"