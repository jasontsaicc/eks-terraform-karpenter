# AWS EKS with GitOps 完整部署指南

這是一個完整的 AWS EKS 集群部署指南，包含 Terraform 基礎設施、Karpenter 自動擴展、GitLab Runner，以及其他必要服務的安裝和配置。

## 📋 目錄

- [先決條件](#先決條件)
- [架構概覽](#架構概覽)
- [快速開始](#快速開始)
- [詳細部署步驟](#詳細部署步驟)
- [服務配置](#服務配置)
- [故障排除](#故障排除)
- [清理資源](#清理資源)
- [最佳實踐](#最佳實踐)

## 🔧 先決條件

### 必要工具
- **AWS CLI v2**: `aws --version`
- **Terraform >= 1.5.0**: `terraform --version`
- **kubectl**: `kubectl version --client`
- **Helm v3**: `helm version`

### AWS 權限要求
確保您的 AWS 帳戶具有以下權限：
- EKS 集群管理
- VPC 和網路資源管理
- IAM 角色和策略管理
- EC2 實例管理
- S3 和 DynamoDB 存取

### 初始設置
```bash
# 配置 AWS CLI
aws configure

# 驗證 AWS 身份
aws sts get-caller-identity

# 設置區域
export AWS_DEFAULT_REGION=ap-southeast-1
```

## 🏗️ 架構概覽

```
┌─────────────────────────────────────────────────────────────┐
│                     AWS EKS 集群架構                          │
├─────────────────────────────────────────────────────────────┤
│  VPC (10.0.0.0/16)                                        │
│  ┌─────────────────┬─────────────────┬─────────────────┐    │
│  │ Public Subnet   │ Private Subnet  │ Private Subnet  │    │
│  │ (1a)           │ (1a)           │ (1b)           │    │
│  │                │                │                │    │
│  │ NAT Gateway    │ EKS Nodes      │ EKS Nodes      │    │
│  │ Internet GW    │ Karpenter      │ GitLab Runner  │    │
│  └─────────────────┴─────────────────┴─────────────────┘    │
└─────────────────────────────────────────────────────────────┘

服務組件：
• EKS Control Plane (Managed)
• EKS Node Groups (t3.small, On-Demand)
• Karpenter (自動擴展)
• AWS Load Balancer Controller
• Metrics Server
• GitLab Runner (可選)
```

## 🚀 快速開始

### 1. 克隆並準備項目
```bash
cd /path/to/project
git clone <repository-url>
cd aws_eks_terraform
```

### 2. 配置 Terraform 變數
```bash
# 使用提供的簡化配置
cp terraform.tfvars.simple terraform.tfvars

# 編輯配置以符合您的需求
vi terraform.tfvars
```

### 3. 初始化和部署
```bash
# 初始化 Terraform
terraform init -backend-config=backend-config.hcl

# 查看部署計劃
terraform plan

# 執行部署
terraform apply -auto-approve
```

### 4. 配置 kubectl
```bash
# 配置 kubectl
aws eks update-kubeconfig --region ap-southeast-1 --name eks-lab-test-eks --kubeconfig ~/.kube/config-eks

# 設置環境變數
export KUBECONFIG=~/.kube/config-eks

# 驗證連接
kubectl cluster-info
kubectl get nodes
```

## 📝 詳細部署步驟

### 步驟 1：基礎設施部署

#### Terraform 配置說明
```hcl
# terraform.tfvars 關鍵配置
project_name = "eks-lab"
environment  = "test"
region       = "ap-southeast-1"

# VPC 配置
vpc_cidr           = "10.0.0.0/16"
enable_nat_gateway = true
single_nat_gateway = true  # 成本優化

# EKS 配置
cluster_version = "1.30"
node_instance_types = ["t3.small"]
node_capacity_type  = "ON_DEMAND"

# 功能啟用
enable_irsa                         = true
enable_ebs_csi_driver              = true
enable_karpenter                    = true
enable_aws_load_balancer_controller = true
```

#### 執行部署
```bash
# 1. 初始化 Terraform
terraform init -backend-config=backend-config.hcl

# 2. 驗證配置
terraform validate

# 3. 查看計劃
terraform plan -out=eks.tfplan

# 4. 執行部署
terraform apply eks.tfplan

# 5. 獲取輸出
terraform output
```

### 步驟 2：集群連接配置

```bash
# 配置 kubectl
aws eks update-kubeconfig \
  --region ap-southeast-1 \
  --name eks-lab-test-eks \
  --kubeconfig ~/.kube/config-eks

# 設置環境變數
export KUBECONFIG=~/.kube/config-eks

# 驗證集群狀態
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
```

### 步驟 3：安裝 Karpenter

#### 自動安裝腳本
```bash
# 執行 Karpenter 安裝腳本
chmod +x scripts/install-karpenter.sh
./scripts/install-karpenter.sh
```

#### 手動安裝步驟
```bash
# 1. 創建 OIDC 提供者
CLUSTER_NAME=eks-lab-test-eks
OIDC_ISSUER_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text)

# 2. 創建 IAM 角色
# (詳見腳本內容)

# 3. 安裝 Helm Chart
helm repo add karpenter https://charts.karpenter.sh/
helm install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --version "0.16.3" \
  --set "settings.aws.clusterName=${CLUSTER_NAME}"

# 4. 創建 NodePool 和 EC2NodeClass
kubectl apply -f karpenter-resources.yaml
```

### 步驟 4：安裝其他服務

#### AWS Load Balancer Controller
```bash
# 創建 IAM 角色和策略
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME=eks-lab-test-eks

# 創建服務帳戶
kubectl create serviceaccount aws-load-balancer-controller -n kube-system

# 附加 IAM 角色
kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME}"

# 安裝 Helm Chart
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-southeast-1 \
  --set vpcId=$(terraform output -raw vpc_id)
```

#### Metrics Server
```bash
# 安裝 Metrics Server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 驗證安裝
kubectl get pods -n kube-system -l k8s-app=metrics-server
```

#### GitLab Runner (可選)
```bash
# 準備配置
cp gitlab-runner-values.yaml gitlab-runner-custom-values.yaml

# 編輯配置，添加您的 GitLab URL 和 Registration Token
vi gitlab-runner-custom-values.yaml

# 安裝 GitLab Runner
helm repo add gitlab https://charts.gitlab.io
helm install gitlab-runner gitlab/gitlab-runner \
  -n gitlab-runner \
  --create-namespace \
  -f gitlab-runner-custom-values.yaml
```

## ⚙️ 服務配置

### Karpenter 配置

#### NodePool 配置範例
```yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        node-type: "karpenter"
    spec:
      nodeClassRef:
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In  
          values: ["t3.medium", "t3.large", "c5.large", "m5.large"]
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
  limits:
    cpu: 1000
    memory: 1000Gi
```

#### EC2NodeClass 配置
```yaml
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  instanceProfile: "KarpenterNodeInstanceProfile-eks-lab-test-eks"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-lab-test-eks"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "eks-lab-test-eks"
  amiFamily: AL2023
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh eks-lab-test-eks
```

### 監控配置

#### 檢查資源使用狀況
```bash
# 查看節點資源使用
kubectl top nodes

# 查看 Pod 資源使用
kubectl top pods -A

# 查看 Karpenter 日誌
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter

# 監控集群事件
kubectl get events --sort-by='.lastTimestamp' -A
```

### 網路配置

#### 創建 LoadBalancer 服務
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-loadbalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: nginx
```

## 🔍 故障排除

### 常見問題及解決方案

#### 1. Karpenter Pod 崩潰
```bash
# 檢查日誌
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# 常見原因：CLUSTER_NAME 或 CLUSTER_ENDPOINT 未設置
# 解決方案：更新 ConfigMap
kubectl patch configmap karpenter-global-settings -n karpenter -p '{
  "data": {
    "aws.clusterName": "eks-lab-test-eks",
    "aws.clusterEndpoint": "https://your-cluster-endpoint.amazonaws.com"
  }
}'

kubectl rollout restart deployment/karpenter -n karpenter
```

#### 2. AWS Load Balancer Controller 問題
```bash
# 檢查權限
kubectl describe sa aws-load-balancer-controller -n kube-system

# 檢查日誌
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 重新安裝
helm uninstall aws-load-balancer-controller -n kube-system
# 然後重新安裝
```

#### 3. 節點無法加入集群
```bash
# 檢查節點組狀態
aws eks describe-nodegroup --cluster-name eks-lab-test-eks --nodegroup-name general

# 檢查安全組配置
aws ec2 describe-security-groups --group-ids $(terraform output -raw cluster_security_group_id)

# 檢查子網路配置
kubectl get nodes -o wide
```

### 除錯命令集合
```bash
# 集群狀態檢查
kubectl cluster-info dump > cluster-dump.log

# 獲取所有資源狀態
kubectl get all -A -o wide

# 檢查節點詳細資訊
kubectl describe nodes

# 檢查系統事件
kubectl get events --sort-by='.lastTimestamp' -A
```

## 🧹 清理資源

### 使用 Terraform 清理
```bash
# 標準清理
terraform destroy -auto-approve
```

### 強制清理腳本
```bash
# 如果 Terraform 清理失敗，使用強制清理
chmod +x scripts/force-cleanup.sh
./scripts/force-cleanup.sh
```

### 手動清理檢查清單
```bash
# 1. 檢查 EKS 集群
aws eks list-clusters --region ap-southeast-1

# 2. 檢查 NAT Gateways
aws ec2 describe-nat-gateways --filter "Name=state,Values=available"

# 3. 檢查 Load Balancers
aws elbv2 describe-load-balancers
aws elb describe-load-balancers

# 4. 檢查 VPC
aws ec2 describe-vpcs --filters "Name=is-default,Values=false"

# 5. 檢查未附加的 Elastic IPs
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'
```

## 💡 最佳實踐

### 成本優化
1. **使用 Spot 實例**: 在 Karpenter NodePool 中配置 Spot 實例
2. **單一 NAT Gateway**: 在非生產環境中使用單一 NAT Gateway
3. **資源監控**: 定期監控資源使用狀況和成本
4. **自動清理**: 設置標籤策略，定期清理未使用資源

### 安全最佳實踐
1. **IAM 最小權限**: 使用最小必要權限原則
2. **網路分割**: 適當配置安全組和網路政策
3. **加密**: 啟用 EBS 和 S3 加密
4. **定期更新**: 定期更新 Kubernetes 版本和節點映像

### 運營最佳實踐
1. **標籤策略**: 為所有資源設置一致的標籤
2. **監控告警**: 設置適當的監控和告警
3. **備份策略**: 定期備份重要數據和配置
4. **文檔維護**: 保持部署文檔的更新

## 📞 支援和貢獻

### 獲取幫助
- 檢查 [故障排除](#故障排除) 部分
- 查看 AWS EKS 官方文檔
- 參考 Karpenter 官方指南

### 貢獻指南
1. Fork 此專案
2. 創建功能分支
3. 提交更改
4. 創建 Pull Request

---

## 🎯 總結

通過本指南，您已成功建立了一個完整的 AWS EKS 環境，包含：

✅ **完整的基礎設施**: VPC、EKS 集群、節點組  
✅ **自動擴展能力**: Karpenter 配置  
✅ **負載平衡**: AWS Load Balancer Controller  
✅ **監控能力**: Metrics Server  
✅ **CI/CD 就緒**: GitLab Runner 配置  
✅ **成本優化**: Spot 實例和單一 NAT Gateway  
✅ **完整文檔**: 部署、配置和故障排除指南  

這個環境現在已準備好用於開發、測試和生產工作負載，並具備企業級的可擴展性和可靠性。