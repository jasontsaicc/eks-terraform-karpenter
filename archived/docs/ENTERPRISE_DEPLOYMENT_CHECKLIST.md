# Enterprise EKS Deployment Checklist

## 🎯 Pre-Deployment Phase

### Account and Permissions
- [ ] AWS Account ID: _______________
- [ ] AWS Region: _______________
- [ ] IAM User/Role has required permissions
- [ ] MFA is enabled for production deployments
- [ ] AWS CLI configured and tested: `aws sts get-caller-identity`

### Resource Planning
- [ ] Project prefix defined: _______________
- [ ] Environment name: _______________
- [ ] No naming conflicts with existing resources
- [ ] Cost center/billing tags defined
- [ ] Resource quotas verified:
  - [ ] EC2 instance limits
  - [ ] VPC limits
  - [ ] Elastic IP limits
  - [ ] NAT Gateway limits

### Network Planning
- [ ] VPC CIDR chosen: _______________
- [ ] No overlap with existing VPCs
- [ ] No overlap with on-premises networks
- [ ] No overlap with VPN/Direct Connect routes
- [ ] Subnet allocation planned:
  - [ ] Public subnets: _______________
  - [ ] Private subnets: _______________
- [ ] DNS resolution strategy defined

### Security Planning
- [ ] Cluster endpoint access strategy:
  - [ ] Public only
  - [ ] Private only
  - [ ] Public and Private
- [ ] Allowed CIDRs for public access: _______________
- [ ] RBAC strategy documented
- [ ] Service account permissions mapped
- [ ] Secrets management approach defined
- [ ] Network security groups reviewed

## 📦 Terraform Configuration

### Backend Setup
- [ ] S3 bucket created for state: _______________
- [ ] DynamoDB table created for locking: _______________
- [ ] Backend configuration tested
- [ ] State encryption enabled
- [ ] Versioning enabled on S3 bucket

### Configuration Files
- [ ] `terraform.tfvars` created from template
- [ ] All variables reviewed and set
- [ ] Sensitive values stored in secrets manager
- [ ] Cost optimization settings configured:
  - [ ] Single NAT Gateway for dev/test: _______________
  - [ ] SPOT instances for non-critical workloads: _______________
  - [ ] Auto-scaling settings reviewed

### Code Review
- [ ] VPC module NAT Gateway routes verified (check line 168-176 in modules/vpc/main.tf)
- [ ] IAM roles and policies reviewed
- [ ] Security group rules reviewed
- [ ] No hardcoded secrets or credentials
- [ ] Resource tags consistent

## 🚀 Deployment Phase

### Phase 1: VPC Infrastructure
- [ ] Run: `terraform plan -target=module.vpc`
- [ ] Review plan output - no unexpected changes
- [ ] Run: `terraform apply -target=module.vpc`
- [ ] Verify VPC created: `aws ec2 describe-vpcs`
- [ ] Run network verification: `./scripts/verify-network.sh`
- [ ] **CRITICAL**: Verify NAT Gateway routes exist:
  ```bash
  aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[].Routes[?DestinationCidrBlock=='0.0.0.0/0']"
  ```

### Phase 2: IAM Resources
- [ ] Run: `terraform plan -target=module.iam`
- [ ] Review IAM roles and policies
- [ ] Run: `terraform apply -target=module.iam`
- [ ] Verify roles created:
  ```bash
  aws iam list-roles | grep -i eks
  ```

### Phase 3: EKS Cluster
- [ ] Run: `terraform plan -target=aws_eks_cluster.main`
- [ ] Verify cluster configuration
- [ ] Run: `terraform apply -target=aws_eks_cluster.main`
- [ ] Wait for cluster ACTIVE status (10-15 minutes)
- [ ] Update kubeconfig:
  ```bash
  aws eks update-kubeconfig --name CLUSTER_NAME --region REGION
  ```
- [ ] Test cluster access: `kubectl get svc`

### Phase 4: OIDC Provider
- [ ] Get OIDC URL:
  ```bash
  aws eks describe-cluster --name CLUSTER_NAME --query "cluster.identity.oidc.issuer"
  ```
- [ ] Create OIDC provider:
  ```bash
  eksctl utils associate-iam-oidc-provider --cluster CLUSTER_NAME --approve
  ```
- [ ] Verify OIDC provider created

### Phase 5: Node Groups
- [ ] Run: `terraform plan -target=aws_eks_node_group.main`
- [ ] Verify node group configuration:
  - [ ] Instance types appropriate
  - [ ] Capacity type (SPOT/ON_DEMAND) correct
  - [ ] Subnets are private subnets
- [ ] Run: `terraform apply -target=aws_eks_node_group.main`
- [ ] Monitor node group creation:
  ```bash
  aws eks describe-nodegroup --cluster-name CLUSTER_NAME --nodegroup-name NODE_GROUP_NAME
  ```
- [ ] Wait for nodes to join (5-10 minutes):
  ```bash
  kubectl get nodes -w
  ```
- [ ] Verify all nodes READY

## 🔧 Add-ons Deployment

### AWS Load Balancer Controller
- [ ] Create IAM policy
- [ ] Create IAM role with OIDC
- [ ] Install via Helm:
  ```bash
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=CLUSTER_NAME
  ```
- [ ] Verify pods running: `kubectl get pods -n kube-system | grep aws-load`

### Karpenter
- [ ] Create Karpenter IAM roles
- [ ] Install Karpenter via Helm
- [ ] Configure NodePool
- [ ] Test autoscaling with sample workload

### Monitoring
- [ ] Install Metrics Server
- [ ] Verify metrics available: `kubectl top nodes`
- [ ] Install Prometheus (optional)
- [ ] Install Grafana (optional)

## ✅ Post-Deployment Validation

### Cluster Health
- [ ] All nodes in READY state
- [ ] All system pods running
- [ ] CoreDNS pods running
- [ ] Network connectivity verified

### Security Validation
- [ ] Cluster endpoint access as expected
- [ ] Security groups properly configured
- [ ] RBAC policies applied
- [ ] Pod security policies enabled (if required)

### Application Testing
- [ ] Deploy test application
- [ ] Test internal service communication
- [ ] Test external ingress (if configured)
- [ ] Test persistent volumes (if using EBS)
- [ ] Test autoscaling

### Cost Verification
- [ ] Verify instance types as planned
- [ ] Verify SPOT instances if configured
- [ ] Check for unnecessary resources
- [ ] Enable cost allocation tags

## 📝 Documentation

### Update Documentation
- [ ] Cluster access instructions documented
- [ ] RBAC roles and permissions documented
- [ ] Network topology diagram updated
- [ ] Disaster recovery procedures documented
- [ ] Runbook for common operations created

### Handover Checklist
- [ ] kubectl access configured for team
- [ ] Monitoring dashboards configured
- [ ] Alerts configured
- [ ] Backup procedures in place
- [ ] Team trained on operations

## 🔄 Rollback Plan

### If Issues Occur
- [ ] Backup current state: `terraform state pull > backup.tfstate`
- [ ] Document the issue
- [ ] If critical, initiate rollback:
  ```bash
  terraform destroy -target=aws_eks_node_group.main
  terraform destroy -target=aws_eks_cluster.main
  terraform destroy -target=module.iam
  terraform destroy -target=module.vpc
  ```

### Emergency Contacts
- AWS Support: _______________
- Team Lead: _______________
- Security Team: _______________
- Network Team: _______________

## 📊 Sign-off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Deployer | | | |
| Team Lead | | | |
| Security Review | | | |
| Network Review | | | |

---
**Deployment Date**: _______________
**Deployment Version**: _______________
**Next Review Date**: _______________