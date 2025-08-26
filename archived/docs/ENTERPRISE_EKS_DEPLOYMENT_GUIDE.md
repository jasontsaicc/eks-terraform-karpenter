# Enterprise EKS Deployment Guide with Karpenter

## Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Pre-deployment Checklist](#pre-deployment-checklist)
4. [Resource Naming Conventions](#resource-naming-conventions)
5. [Environment Configuration](#environment-configuration)
6. [Phase 1: Infrastructure Deployment](#phase-1-infrastructure-deployment)
7. [Phase 2: EKS Add-ons Configuration](#phase-2-eks-add-ons-configuration)
8. [Phase 3: Karpenter Setup](#phase-3-karpenter-setup)
9. [Validation and Testing](#validation-and-testing)
10. [Cost Optimization](#cost-optimization)
11. [Security Best Practices](#security-best-practices)
12. [Troubleshooting](#troubleshooting)
13. [Rollback Procedures](#rollback-procedures)

## Overview

This guide provides step-by-step instructions for deploying Amazon EKS with Karpenter in enterprise AWS accounts. The deployment is designed to:

- Work safely with existing AWS resources
- Minimize costs through intelligent resource management
- Follow enterprise security best practices
- Support multiple teams and environments
- Provide easy rollback capabilities

## Prerequisites

### Required Tools
- AWS CLI v2.15.0 or later
- Terraform v1.5.0 or later
- kubectl v1.30.0 or later
- helm v3.12.0 or later
- jq for JSON processing

### AWS Permissions
Ensure your AWS user/role has the following permissions:
- EC2 Full Access
- EKS Full Access
- IAM Full Access
- VPC Full Access
- Route53 (if using custom domains)
- Certificate Manager (if using TLS)

### Network Requirements
- Available IP space that doesn't conflict with existing VPCs
- NAT Gateway or NAT Instance for private subnet internet access
- DNS resolution configured

## Pre-deployment Checklist

### ✅ Account Verification
- [ ] Confirm AWS account ID and region
- [ ] Verify service quotas for EC2 instances and EKS clusters
- [ ] Check existing resource names to avoid conflicts
- [ ] Ensure AWS CLI is configured with correct credentials

### ✅ Network Planning
- [ ] Choose VPC CIDR that doesn't overlap with existing networks
- [ ] Plan subnet allocation across availability zones
- [ ] Verify internet access requirements for private subnets
- [ ] Document existing security groups and NACLs

### ✅ Naming and Tagging Strategy
- [ ] Define project naming convention
- [ ] Establish environment naming (dev, staging, prod)
- [ ] Plan resource tagging strategy for cost allocation
- [ ] Coordinate with other teams to avoid conflicts

### ✅ Security Planning
- [ ] Define cluster endpoint access requirements
- [ ] Plan RBAC strategy for different teams
- [ ] Review security group requirements
- [ ] Plan secrets management approach

### ✅ Backup Strategy
- [ ] Plan Terraform state backup
- [ ] Document configuration backup procedures
- [ ] Test rollback procedures in non-production environment

## Resource Naming Conventions

To avoid conflicts with existing resources, use this naming pattern:

```
{organization}-{team}-{environment}-{resource-type}-{purpose}
```

### Examples:
- VPC: `acme-platform-prod-vpc-eks`
- EKS Cluster: `acme-platform-prod-eks-main`
- Node Groups: `acme-platform-prod-ng-general`
- IAM Roles: `acme-platform-prod-role-eks-cluster`

### Reserved Prefixes to Avoid:
- `aws-*` (AWS managed resources)
- `kubernetes-*` (Kubernetes system resources)
- `karpenter-*` (Karpenter managed resources)

## Environment Configuration

### 1. Initialize Terraform Backend
First, create a secure S3 backend for state management:

```bash
# Create S3 bucket for Terraform state
aws s3 mb s3://your-org-terraform-state-$(date +%s) --region us-west-2

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name your-org-terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-west-2
```

### 2. Configure terraform.tfvars

Create a customized configuration:

```hcl
# terraform.tfvars
project_name = "your-company"
environment  = "production"
region      = "us-west-2"

# Network Configuration
vpc_cidr = "10.100.0.0/16"  # Ensure no conflicts
azs      = ["us-west-2a", "us-west-2b", "us-west-2c"]

# Cost Optimization Settings
single_nat_gateway = false  # Use 'true' for dev/test environments
enable_nat_gateway = true
node_capacity_type = "SPOT"  # Use SPOT instances for cost savings

# EKS Configuration
cluster_version = "1.30"
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # Restrict in production

# Node Group Settings
node_instance_types = ["m5.large", "m5a.large", "m4.large"]
node_group_desired_size = 2
node_group_min_size     = 1
node_group_max_size     = 10

# Feature Flags
enable_karpenter = true
enable_aws_load_balancer_controller = true
enable_ebs_csi_driver = true
enable_irsa = true

# Tags
tags = {
  Environment = "production"
  Team        = "platform"
  ManagedBy   = "Terraform"
  Project     = "eks-infrastructure"
  CostCenter  = "engineering"
}
```

## Phase 1: Infrastructure Deployment

### Step 1: Plan the Deployment
Always run a plan before applying:

```bash
terraform init
terraform plan -var-file="terraform.tfvars"
```

**⚠️ Safety Check:** Review the plan output carefully:
- Verify no existing resources will be destroyed
- Check resource names follow conventions
- Confirm subnet CIDR allocations
- Validate security group rules

### Step 2: Deploy VPC Infrastructure
Deploy in phases to minimize risk:

```bash
# Deploy VPC only first
terraform apply -target=module.vpc -var-file="terraform.tfvars"
```

**Validation:**
```bash
# Verify VPC creation
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*your-company*"

# Check subnet allocation
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)"

# Verify NAT Gateway routes
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)"
```

### Step 3: Deploy IAM Roles
```bash
terraform apply -target=module.iam -var-file="terraform.tfvars"
```

**Validation:**
```bash
# Verify IAM roles
aws iam list-roles --query 'Roles[?contains(RoleName, `your-company`)]'
```

### Step 4: Deploy EKS Cluster
```bash
terraform apply -target=aws_eks_cluster.main -var-file="terraform.tfvars"
```

**Validation:**
```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-west-2 --name $(terraform output -raw cluster_name)

# Verify cluster access
kubectl get nodes
kubectl get pods -A
```

### Step 5: Deploy Node Groups
```bash
terraform apply -target=aws_eks_node_group.main -var-file="terraform.tfvars"
```

**Validation:**
```bash
# Check node status
kubectl get nodes -o wide

# Verify node group in AWS console
aws eks describe-nodegroup --cluster-name $(terraform output -raw cluster_name) --nodegroup-name general
```

## Phase 2: EKS Add-ons Configuration

### AWS Load Balancer Controller

```bash
# Add Helm repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$(terraform output -raw cluster_name) \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw aws_load_balancer_controller_role_arn)
```

### EBS CSI Driver

```bash
# Enable EBS CSI Driver add-on
aws eks create-addon \
  --cluster-name $(terraform output -raw cluster_name) \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn $(terraform output -raw ebs_csi_driver_role_arn) \
  --resolve-conflicts OVERWRITE
```

### Validation
```bash
# Verify add-ons
kubectl get pods -n kube-system
aws eks describe-addon --cluster-name $(terraform output -raw cluster_name) --addon-name aws-ebs-csi-driver
```

## Phase 3: Karpenter Setup

### Install Karpenter

```bash
# Set environment variables
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export AWS_DEFAULT_REGION=$(terraform output -raw region)
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KARPENTER_VERSION=v0.37.0

# Add Karpenter Helm repository
helm repo add karpenter https://charts.karpenter.sh/
helm repo update

# Install Karpenter
helm install karpenter karpenter/karpenter \
  --version ${KARPENTER_VERSION} \
  --namespace karpenter \
  --create-namespace \
  --set settings.aws.clusterName=${CLUSTER_NAME} \
  --set settings.aws.defaultInstanceProfile=$(terraform output -raw karpenter_instance_profile_name) \
  --set settings.aws.interruptionQueueName=${CLUSTER_NAME} \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter
```

### Configure Karpenter NodePool

```yaml
# karpenter-nodepool.yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        node-type: "karpenter-managed"
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: 
            - m5.large
            - m5.xlarge
            - m5.2xlarge
            - m5a.large
            - m5a.xlarge
            - m5a.2xlarge
            - m4.large
            - m4.xlarge
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
      taints:
        - key: karpenter.sh/unschedulable
          value: "true"
          effect: NoSchedule
  limits:
    cpu: 1000
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
    expireAfter: 2160h # 90 days
---
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "$(terraform output -raw cluster_name)"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "$(terraform output -raw cluster_name)"
  instanceStorePolicy: NVME
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh $(terraform output -raw cluster_name)
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    sysctl -p
  tags:
    ManagedBy: Karpenter
    Environment: "production"
```

Apply the configuration:
```bash
envsubst < karpenter-nodepool.yaml | kubectl apply -f -
```

## Validation and Testing

### Infrastructure Validation

```bash
# Test VPC connectivity
kubectl run test-pod --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default

# Test internet connectivity from pods
kubectl run test-internet --image=busybox --rm -it --restart=Never -- wget -qO- http://ifconfig.me

# Test persistent volumes
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-pvc
```

### Karpenter Testing

```bash
# Deploy test workload to trigger Karpenter
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
spec:
  replicas: 10
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      containers:
      - name: test
        image: busybox
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF

# Watch Karpenter provision nodes
kubectl logs -f -n karpenter -c controller -l app.kubernetes.io/name=karpenter

# Verify new nodes are created
kubectl get nodes -l node-type=karpenter-managed
```

## Cost Optimization

### Configuration Options

1. **Use Spot Instances (50-90% cost reduction)**
   ```hcl
   node_capacity_type = "SPOT"
   ```

2. **Single NAT Gateway for Non-Production**
   ```hcl
   single_nat_gateway = true  # Saves ~$90/month per AZ
   ```

3. **Graviton Instances (20% better price/performance)**
   ```yaml
   # In Karpenter NodePool
   requirements:
     - key: kubernetes.io/arch
       operator: In
       values: ["arm64"]
     - key: node.kubernetes.io/instance-type
       operator: In
       values: 
         - m6g.medium
         - m6g.large
         - m6g.xlarge
   ```

4. **Enable Cluster Autoscaler for Traditional Node Groups**
   ```bash
   helm install cluster-autoscaler autoscaler/cluster-autoscaler \
     --namespace kube-system \
     --set autoDiscovery.clusterName=$(terraform output -raw cluster_name) \
     --set awsRegion=$(terraform output -raw region)
   ```

### Cost Monitoring

```bash
# Tag all resources for cost allocation
aws resourcegroupstaggingapi get-resources \
  --resource-type-filters "ec2:instance" \
  --tag-filters Key=Environment,Values=production
```

## Security Best Practices

### 1. Network Security

```bash
# Restrict cluster endpoint access (Production)
terraform apply -var="cluster_endpoint_public_access_cidrs=[\"YOUR-OFFICE-IP/32\"]"
```

### 2. Pod Security Standards

```yaml
# pod-security-standards.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production-apps
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### 3. RBAC Configuration

```yaml
# rbac-example.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: developer
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps", "secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developer-binding
subjects:
- kind: User
  name: developer@company.com
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: developer
  apiGroup: rbac.authorization.k8s.io
```

### 4. Secrets Management

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets-system --create-namespace

# Example SecretStore for AWS Secrets Manager
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: $(terraform output -raw region)
      auth:
        secretRef:
          accessKeyID:
            name: aws-secret
            key: access-key-id
          secretAccessKey:
            name: aws-secret
            key: secret-access-key
EOF
```

## Troubleshooting

### Common Issues

#### 1. Nodes Not Joining Cluster

**Symptoms:**
- Nodes show in EC2 but not in `kubectl get nodes`
- Node status stuck in "NotReady"

**Solutions:**
```bash
# Check node logs
aws ssm start-session --target INSTANCE_ID

# On the node, check logs
sudo journalctl -u kubelet -f

# Verify security groups allow communication
aws ec2 describe-security-groups --group-ids $(terraform output -raw cluster_security_group_id)
```

#### 2. Pods Cannot Access Internet

**Symptoms:**
- DNS resolution fails
- Cannot pull container images
- External API calls timeout

**Solutions:**
```bash
# Check NAT Gateway routes
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)"

# Verify NAT Gateway is running
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$(terraform output -raw vpc_id)"

# Test from within pod
kubectl run debug --image=busybox --rm -it --restart=Never -- nslookup google.com
```

#### 3. Karpenter Not Provisioning Nodes

**Symptoms:**
- Pending pods with "Insufficient capacity" errors
- No new nodes appearing

**Solutions:**
```bash
# Check Karpenter logs
kubectl logs -n karpenter -c controller -l app.kubernetes.io/name=karpenter

# Verify NodePool configuration
kubectl get nodepool default -o yaml

# Check instance profile permissions
aws iam get-role --role-name $(terraform output -raw karpenter_instance_profile_name | cut -d'/' -f2)
```

### Debug Commands

```bash
# Cluster information
kubectl cluster-info dump

# Check all resource quotas
kubectl describe quota --all-namespaces

# View events
kubectl get events --sort-by='.metadata.creationTimestamp'

# Check node resource usage
kubectl top nodes
kubectl top pods --all-namespaces
```

## Rollback Procedures

### Emergency Rollback

If critical issues occur, follow these steps:

#### 1. Application Level Rollback
```bash
# Rollback specific deployment
kubectl rollout undo deployment/app-name -n namespace

# Check rollout status
kubectl rollout status deployment/app-name -n namespace
```

#### 2. Infrastructure Rollback
```bash
# Identify last good state
terraform state list

# Create backup of current state
cp terraform.tfstate terraform.tfstate.backup

# Rollback to previous Terraform state
terraform apply -target=resource.name -var-file="terraform.tfvars.backup"
```

#### 3. Complete Infrastructure Teardown
⚠️ **Use only in emergencies**

```bash
# Remove all Kubernetes resources first
kubectl delete all --all --all-namespaces

# Remove Helm releases
helm list --all-namespaces
helm uninstall release-name -n namespace

# Destroy Terraform infrastructure
terraform destroy -var-file="terraform.tfvars"
```

### Graceful Rollback Process

For planned rollbacks:

1. **Scale down workloads**
   ```bash
   kubectl scale deployment/app --replicas=0
   ```

2. **Remove Karpenter nodes gracefully**
   ```bash
   kubectl delete nodepool default
   ```

3. **Wait for node termination**
   ```bash
   kubectl get nodes -w
   ```

4. **Rollback Terraform changes**
   ```bash
   git checkout previous-working-commit
   terraform plan -var-file="terraform.tfvars"
   terraform apply -var-file="terraform.tfvars"
   ```

## Monitoring and Maintenance

### Set up CloudWatch Logging
```bash
# Enable container insights
aws logs create-log-group --log-group-name /aws/eks/$(terraform output -raw cluster_name)/cluster

# Install CloudWatch agent
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/cloudwatch-namespace.yaml
```

### Regular Maintenance Tasks

1. **Weekly:**
   - Review cluster resource usage
   - Check for pending security patches
   - Validate backup procedures

2. **Monthly:**
   - Update cluster version (during maintenance window)
   - Review and optimize costs
   - Test disaster recovery procedures

3. **Quarterly:**
   - Security assessment
   - Architecture review
   - Update documentation

## Support and Contacts

For issues or questions:

1. **Infrastructure Team:** platform@company.com
2. **Security Team:** security@company.com
3. **AWS Support:** [AWS Support Console](https://console.aws.amazon.com/support/)
4. **Emergency Contact:** +1-XXX-XXX-XXXX

## Additional Resources

- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter Documentation](https://karpenter.sh/docs/)
- [Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

---

**Document Version:** 1.0  
**Last Updated:** $(date)  
**Next Review Date:** $(date -d "+3 months")