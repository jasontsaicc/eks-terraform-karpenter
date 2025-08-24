# AWS EKS 完整部署手冊 - 手動 vs 自動化對比

> **作者**: jasontsai  
> **Repository**: https://github.com/jasontsaicc/eks-terraform-karpenter  
> **最後更新**: 2024-12

## 📋 目錄

1. [前置準備](#前置準備)
2. [方法 A: 完整手動部署](#方法-a-完整手動部署)
3. [方法 B: 使用自動化腳本](#方法-b-使用自動化腳本)
4. [步驟對比分析](#步驟對比分析)
5. [故障排除](#故障排除)
6. [清理資源](#清理資源)

---

## 前置準備

### 必要工具安裝

```bash
# 檢查必要工具
which terraform kubectl helm aws jq

# 如果缺少，安裝它們
# macOS
brew install terraform kubectl helm awscli jq

# Linux (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y curl unzip jq

# Terraform
wget https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_amd64.zip
unzip terraform_1.5.7_linux_amd64.zip
sudo mv terraform /usr/local/bin/

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

### AWS 認證設置

```bash
# 配置 AWS credentials
aws configure
# AWS Access Key ID: YOUR_ACCESS_KEY
# AWS Secret Access Key: YOUR_SECRET_KEY
# Default region name: ap-southeast-1
# Default output format: json

# 驗證
aws sts get-caller-identity

# 設置環境變數
export AWS_REGION=ap-southeast-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

---

## 方法 A: 完整手動部署

### Step A1: 創建 Terraform Backend (S3 + DynamoDB)

```bash
# 1. 進入 backend 目錄
cd terraform-backend

# 2. 初始化 Terraform
terraform init

# 3. 查看將要創建的資源
terraform plan

# 4. 創建 backend 資源
terraform apply -auto-approve

# 5. 記錄輸出
export BACKEND_BUCKET=$(terraform output -raw s3_bucket_name)
export BACKEND_REGION=$(terraform output -raw s3_bucket_region)
export BACKEND_DYNAMODB=$(terraform output -raw dynamodb_table_name)

echo "Backend Bucket: $BACKEND_BUCKET"
echo "Backend Region: $BACKEND_REGION"
echo "DynamoDB Table: $BACKEND_DYNAMODB"

# 6. 返回主目錄
cd ..
```

### Step A2: 修正循環依賴問題

由於模組間存在循環依賴，需要分階段部署：

```bash
# 1. 首先只部署 VPC
cat > deploy-vpc-only.tf << 'EOF'
module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr          = var.vpc_cidr
  azs               = var.azs
  enable_nat_gateway = var.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  cluster_name      = "${var.project_name}-${var.environment}-eks"
  enable_flow_logs  = false
  tags              = var.tags
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}
EOF

# 2. 暫時移動主配置
mv main.tf main.tf.backup

# 3. 使用 VPC-only 配置
mv deploy-vpc-only.tf main.tf

# 4. 部署 VPC
terraform init
terraform plan -var-file="terraform-simple.tfvars"
terraform apply -var-file="terraform-simple.tfvars" -auto-approve

# 5. 記錄 VPC 輸出
export VPC_ID=$(terraform output -raw vpc_id)
export PRIVATE_SUBNETS=$(terraform output -json private_subnet_ids)
export PUBLIC_SUBNETS=$(terraform output -json public_subnet_ids)

# 6. 恢復主配置
rm main.tf
mv main.tf.backup main.tf
```

### Step A3: 部署完整 EKS 基礎設施

```bash
# 1. 初始化（使用 backend）
terraform init \
  -backend-config="bucket=$BACKEND_BUCKET" \
  -backend-config="key=eks/terraform.tfstate" \
  -backend-config="region=$BACKEND_REGION" \
  -backend-config="dynamodb_table=$BACKEND_DYNAMODB"

# 2. 導入已創建的 VPC 資源（避免重複創建）
terraform import module.vpc.aws_vpc.main $VPC_ID

# 3. 計劃部署
terraform plan -var-file="terraform-simple.tfvars" -out=eks.tfplan

# 4. 執行部署（約 15-20 分鐘）
terraform apply eks.tfplan

# 5. 獲取輸出
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
export AWS_LB_CONTROLLER_ROLE=$(terraform output -raw aws_load_balancer_controller_role_arn)
export KARPENTER_CONTROLLER_ROLE=$(terraform output -raw karpenter_controller_role_arn)
```

### Step A4: 配置 kubectl

```bash
# 1. 更新 kubeconfig
aws eks update-kubeconfig \
  --region $AWS_REGION \
  --name $CLUSTER_NAME \
  --alias $CLUSTER_NAME

# 2. 驗證連接
kubectl get nodes

# 3. 檢查系統 pods
kubectl get pods -n kube-system
```

### Step A5: 安裝 cert-manager (ALB Controller 前置需求)

```bash
# 1. 安裝 cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# 2. 等待 cert-manager 就緒
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/component=webhook \
  -n cert-manager \
  --timeout=120s

# 3. 驗證安裝
kubectl get pods -n cert-manager
```

### Step A6: 安裝 AWS Load Balancer Controller

```bash
# 1. 添加 Helm repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# 2. 安裝 AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$AWS_LB_CONTROLLER_ROLE \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID \
  --wait

# 3. 驗證安裝
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer
```

### Step A7: 安裝 Karpenter

```bash
# 1. 創建 Karpenter namespace
kubectl create namespace karpenter

# 2. 添加 Helm repository
helm repo add karpenter https://karpenter.sh/charts
helm repo update

# 3. 安裝 Karpenter
helm upgrade --install karpenter karpenter/karpenter \
  --namespace karpenter \
  --version v0.35.0 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_CONTROLLER_ROLE \
  --set settings.clusterName=$CLUSTER_NAME \
  --set settings.interruptionQueue=$CLUSTER_NAME-karpenter \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --wait

# 4. 應用 Karpenter Provisioners
kubectl apply -f karpenter/provisioners.yaml

# 5. 驗證安裝
kubectl get pods -n karpenter
kubectl get nodepool -n karpenter
kubectl get ec2nodeclass -n karpenter
```

### Step A8: 安裝 ArgoCD

```bash
# 1. 創建 namespace
kubectl create namespace argocd

# 2. 添加 Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# 3. 安裝 ArgoCD
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 5.51.6 \
  -f argocd/values.yaml \
  --wait

# 4. 獲取初始密碼
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo "ArgoCD admin password: $ARGOCD_PASSWORD"

# 5. 應用 Platform Applications
kubectl apply -f gitops-apps/platform-apps.yaml

# 6. Port forward 訪問 UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
echo "ArgoCD UI: https://localhost:8080"
echo "Username: admin"
echo "Password: $ARGOCD_PASSWORD"
```

### Step A9: 安裝監控堆疊 (Prometheus + Grafana)

```bash
# 1. 創建 namespace
kubectl create namespace monitoring

# 2. 添加 Helm repository
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 3. 安裝 kube-prometheus-stack
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 58.7.2 \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp3 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set grafana.adminPassword=changeme \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClassName=gp3 \
  --set grafana.persistence.size=10Gi \
  --wait

# 4. Port forward 訪問 Grafana
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80 &
echo "Grafana UI: http://localhost:3000"
echo "Username: admin"
echo "Password: changeme"
```

### Step A10: 安裝 GitLab (可選)

```bash
# 1. 創建 namespace
kubectl create namespace gitlab

# 2. 添加 Helm repository
helm repo add gitlab https://charts.gitlab.io
helm repo update

# 3. 創建最小化配置
cat > gitlab-minimal-values.yaml << 'EOF'
global:
  hosts:
    domain: example.com
    https: false
  ingress:
    enabled: false
postgresql:
  install: true
  persistence:
    size: 8Gi
redis:
  install: true
  persistence:
    size: 8Gi
minio:
  install: false
gitlab:
  webservice:
    minReplicas: 1
    maxReplicas: 2
  sidekiq:
    minReplicas: 1
    maxReplicas: 2
EOF

# 4. 安裝 GitLab
helm install gitlab gitlab/gitlab \
  --namespace gitlab \
  --version 7.11.0 \
  -f gitlab-minimal-values.yaml \
  --timeout 600s \
  --wait

# 5. 獲取 root 密碼
GITLAB_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab \
  -o jsonpath='{.data.password}' | base64 -d)

echo "GitLab root password: $GITLAB_PASSWORD"
```

---

## 方法 B: 使用自動化腳本

### Step B1: 一鍵部署所有元件

```bash
# 1. 確保腳本可執行
chmod +x scripts/deploy-all.sh

# 2. 設置環境變數（可選）
export AWS_REGION=ap-southeast-1
export SKIP_GITLAB=true  # 跳過 GitLab 安裝

# 3. 執行自動部署
./scripts/deploy-all.sh

# 腳本會自動執行：
# - 檢查前置條件
# - 部署 Terraform Backend
# - 部署 EKS 基礎設施
# - 配置 kubectl
# - 安裝所有 Kubernetes 元件
# - 顯示訪問信息
```

### 腳本內部執行的步驟

```bash
#!/bin/bash
# deploy-all.sh 內部邏輯

# 階段 1: 前置檢查
check_prerequisites() {
  # 檢查 terraform, kubectl, helm, aws, jq
  # 檢查 AWS credentials
}

# 階段 2: Backend 部署
deploy_backend() {
  cd terraform-backend
  terraform init
  terraform apply -auto-approve
  cd ..
}

# 階段 3: EKS 部署
deploy_eks() {
  terraform init
  terraform plan -out=eks.tfplan
  terraform apply eks.tfplan
}

# 階段 4: Kubernetes 配置
configure_kubectl() {
  aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
}

# 階段 5-9: 安裝元件
install_alb_controller()  # cert-manager + ALB Controller
install_karpenter()       # Karpenter + Provisioners
install_argocd()          # ArgoCD + Applications
install_gitlab()          # GitLab (可選)
setup_monitoring()        # Prometheus + Grafana

# 階段 10: 驗證
verify_deployment() {
  kubectl get nodes
  kubectl get pods -A
}
```

---

## 步驟對比分析

### 時間對比

| 步驟 | 手動執行 | 使用腳本 | 節省時間 |
|------|----------|----------|----------|
| 前置檢查 | 5 分鐘 | 10 秒 | 4分50秒 |
| Backend 部署 | 10 分鐘 | 2 分鐘 | 8 分鐘 |
| VPC 部署 | 5 分鐘 | (自動處理) | 5 分鐘 |
| EKS 部署 | 20 分鐘 | 15 分鐘 | 5 分鐘 |
| kubectl 配置 | 3 分鐘 | 30 秒 | 2分30秒 |
| cert-manager | 5 分鐘 | 2 分鐘 | 3 分鐘 |
| ALB Controller | 5 分鐘 | 2 分鐘 | 3 分鐘 |
| Karpenter | 8 分鐘 | 3 分鐘 | 5 分鐘 |
| ArgoCD | 8 分鐘 | 3 分鐘 | 5 分鐘 |
| 監控堆疊 | 10 分鐘 | 5 分鐘 | 5 分鐘 |
| 驗證測試 | 5 分鐘 | 1 分鐘 | 4 分鐘 |
| **總計** | **84 分鐘** | **34 分鐘** | **50 分鐘** |

### 步驟數量對比

| 類型 | 手動步驟數 | 腳本步驟數 | 簡化程度 |
|------|------------|------------|----------|
| 命令執行 | 65+ | 3 | 95% 簡化 |
| 配置文件 | 需手動創建 | 自動使用 | 100% 自動 |
| 錯誤處理 | 手動檢查 | 自動重試 | 自動化 |
| 依賴管理 | 手動處理 | 自動解決 | 自動化 |

### 腳本節省的具體步驟

1. **自動處理循環依賴**
   - 手動：需要分階段部署，修改配置文件
   - 腳本：自動處理模組依賴順序

2. **自動等待資源就緒**
   - 手動：需要反復檢查 pod 狀態
   - 腳本：使用 `--wait` 和 `kubectl wait` 自動等待

3. **自動獲取和傳遞參數**
   - 手動：需要複製粘貼 ARN、ID 等
   - 腳本：自動從 Terraform 輸出獲取並傳遞

4. **自動錯誤重試**
   - 手動：失敗需要手動重新執行
   - 腳本：內建重試邏輯

5. **並行執行**
   - 手動：順序執行每個步驟
   - 腳本：可能的地方並行執行

---

## 故障排除

### 常見問題快速解決

#### 1. Terraform 循環依賴

```bash
# 錯誤: Error: Cycle: module.iam...module.eks...
# 解決方案：分階段部署
terraform apply -target=module.vpc
terraform apply -target=module.iam
terraform apply
```

#### 2. kubectl 無法連接

```bash
# 錯誤: Unable to connect to the server
# 解決方案：
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
kubectl config use-context $CLUSTER_NAME
```

#### 3. Helm 安裝超時

```bash
# 錯誤: Error: timed out waiting for the condition
# 解決方案：增加超時時間
helm install <chart> --timeout 10m --wait
```

#### 4. IRSA 不工作

```bash
# 錯誤: AccessDenied: User: arn:aws:sts::...
# 解決方案：檢查 OIDC Provider
aws eks describe-cluster --name $CLUSTER_NAME \
  --query "cluster.identity.oidc.issuer"
  
# 重新創建 OIDC Provider
eksctl utils associate-iam-oidc-provider \
  --cluster $CLUSTER_NAME \
  --approve
```

#### 5. Karpenter 不創建節點

```bash
# 檢查日誌
kubectl logs -n karpenter deployment/karpenter -f

# 檢查 NodePool
kubectl describe nodepool -n karpenter

# 檢查 IAM 角色
aws iam get-role --role-name karpenter-controller
```

---

## 清理資源

### 方法 A: 手動清理

```bash
# 1. 刪除 Kubernetes 資源
kubectl delete ingress --all --all-namespaces
kubectl delete svc --all --all-namespaces --field-selector spec.type=LoadBalancer

# 2. 卸載 Helm charts
helm list -A | grep -v NAME | awk '{print "helm uninstall " $1 " -n " $2}' | bash

# 3. 刪除 Karpenter 節點
kubectl delete nodepool --all -n karpenter
kubectl delete ec2nodeclass --all -n karpenter

# 4. 等待節點終止
sleep 60

# 5. 銷毀 Terraform 資源
terraform destroy -var-file="terraform-simple.tfvars" -auto-approve

# 6. 清理 Backend（可選）
cd terraform-backend
terraform destroy -auto-approve
```

### 方法 B: 使用清理腳本

```bash
# 一鍵清理所有資源
chmod +x scripts/cleanup-all.sh
./scripts/cleanup-all.sh

# 腳本會：
# 1. 刪除所有 K8s 資源
# 2. 等待 AWS 資源清理
# 3. 銷毀 Terraform 資源
# 4. 可選清理 Backend
# 5. 驗證清理結果
```

---

## 成本優化建議

### 測試環境配置

```yaml
# 使用 Spot 實例
node_capacity_type: SPOT

# 單 NAT Gateway
single_nat_gateway: true

# 較小的實例類型
node_instance_types: ["t3.small", "t3.medium"]

# 最小節點數
node_group_min_size: 1
node_group_desired_size: 2
```

### 生產環境配置

```yaml
# 混合 Spot/On-Demand
node_capacity_type: ["SPOT", "ON_DEMAND"]

# 多 NAT Gateway（高可用）
single_nat_gateway: false

# 適當的實例類型
node_instance_types: ["t3.large", "c5.large", "m5.large"]

# 合理的節點數
node_group_min_size: 3
node_group_desired_size: 5
```

### 成本監控

```bash
# 查看當前成本
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '7 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE

# 設置預算告警
aws budgets create-budget \
  --account-id $AWS_ACCOUNT_ID \
  --budget file://budget.json \
  --notifications-with-subscribers file://notifications.json
```

---

## 總結

### 何時使用手動部署
- 學習和理解每個步驟
- 需要精細控制每個配置
- 調試特定問題
- 部分更新或修改

### 何時使用腳本部署
- 快速搭建完整環境
- 重複部署多個環境
- CI/CD 自動化
- 團隊標準化部署

### 最佳實踐
1. **首次部署**：使用手動方式理解流程
2. **日常使用**：使用腳本提高效率
3. **故障排除**：結合兩種方式
4. **生產部署**：使用腳本 + 人工驗證

---

**作者**: jasontsai  
**最後更新**: 2024-12  
**版本**: 1.0.0