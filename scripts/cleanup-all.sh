#!/bin/bash

# Complete AWS EKS Resources Cleanup Script
# Author: jasontsai

set -e

echo "Starting complete AWS resources cleanup..."

# Configuration
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export KUBECONFIG=/tmp/eks-config

echo "Region: $AWS_REGION"
echo "Cluster: $CLUSTER_NAME"

# Delete Kubernetes resources
echo "Step 1: Deleting Kubernetes resources..."
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null || true
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall karpenter -n karpenter 2>/dev/null || true
kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/v1.16.2/cert-manager.yaml 2>/dev/null || true

# Delete Node Group
echo "Step 2: Deleting Node Group..."
aws eks delete-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name general --region $AWS_REGION 2>/dev/null || true
aws eks wait nodegroup-deleted --cluster-name $CLUSTER_NAME --nodegroup-name general --region $AWS_REGION 2>/dev/null || true

# Delete EKS Cluster
echo "Step 3: Deleting EKS Cluster..."
aws eks delete-cluster --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true
aws eks wait cluster-deleted --name $CLUSTER_NAME --region $AWS_REGION 2>/dev/null || true

# Delete OIDC Provider
echo "Step 4: Deleting OIDC Provider..."
OIDC_ID=7894D9834B8F729C50BD85F05EAEFEE4
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn arn:aws:iam::273528188825:oidc-provider/oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID 2>/dev/null || true

# Delete IAM Roles
echo "Step 5: Deleting IAM Roles..."
aws iam detach-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-arn arn:aws:iam::273528188825:policy/AWSLoadBalancerControllerIAMPolicy 2>/dev/null || true
aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole 2>/dev/null || true
aws iam delete-policy --policy-arn arn:aws:iam::273528188825:policy/AWSLoadBalancerControllerIAMPolicy 2>/dev/null || true

# Delete Terraform resources
echo "Step 6: Deleting Terraform resources..."
cd /home/ubuntu/projects/aws_eks_terraform
terraform destroy -var-file="terraform-simple.tfvars" -auto-approve || true

echo "Cleanup completed!"
