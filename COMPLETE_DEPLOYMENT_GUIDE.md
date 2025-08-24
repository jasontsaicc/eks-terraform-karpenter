# AWS EKS GitOps 基礎設施完整部署指南

> **作者**: jasontsai  
> **Repository**: https://github.com/jasontsaicc/eks-terraform-karpenter  
> **最後更新**: 2024-08

## 📋 目錄

1. [專案概述](#專案概述)
2. [架構設計](#架構設計)
3. [前置準備](#前置準備)
4. [部署步驟](#部署步驟)
5. [服務配置](#服務配置)
6. [日常操作](#日常操作)
7. [成本優化](#成本優化)
8. [故障處理](#故障處理)
9. [清理資源](#清理資源)

## 專案概述

本專案提供完整的 AWS EKS GitOps 基礎設施解決方案，包含：

- **EKS Kubernetes 集群** - 生產級容器編排平台
- **ArgoCD** - GitOps 持續部署
- **GitLab + Runner** - 程式碼管理與 CI/CD
- **Karpenter** - 智能節點自動調配
- **AWS Load Balancer Controller** - 負載均衡管理
- **Prometheus + Grafana** - 監控與可視化

### 技術堆疊

- **IaC**: Terraform v1.5+
- **Kubernetes**: v1.30
- **Container Runtime**: containerd
- **Networking**: AWS VPC CNI
- **Storage**: EBS CSI Driver
- **Ingress**: AWS ALB

## 架構設計

### 網路架構

```
Internet Gateway
    │
    ├── Public Subnets (Multi-AZ)
    │   ├── NAT Gateway
    │   └── ALB (Application Load Balancer)
    │
    └── Private Subnets (Multi-AZ)
        ├── EKS Control Plane (Managed)
        ├── EKS Worker Nodes
        │   ├── System Node Group (On-Demand)
        │   └── Application Nodes (Spot/Karpenter)
        └── RDS/ElastiCache (Optional)
```

### 部署模式選擇

| 環境 | 節點配置 | 成本/月 | 用途 |
|------|----------|---------|------|
| **測試** | 2x t3.medium (Spot) | ~$50 | 開發測試 |
| **預生產** | 3x t3.large (Mixed) | ~$150 | UAT/Staging |
| **生產** | 5x t3.xlarge (On-Demand) | ~$500 | Production |

## 前置準備

### 1. 工具安裝

```bash
# macOS
brew install terraform kubectl helm awscli jq

# Linux
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
wget https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz
```

### 2. AWS 配置

```bash
# 配置 AWS CLI
aws configure
# AWS Access Key ID: YOUR_ACCESS_KEY
# AWS Secret Access Key: YOUR_SECRET_KEY
# Default region name: ap-northeast-1
# Default output format: json

# 驗證身份
aws sts get-caller-identity
```

### 3. 環境變數設置

```bash
export AWS_REGION=ap-northeast-1
export PROJECT_NAME=eks-gitops
export ENVIRONMENT=test
```

## 部署步驟

### Step 1: 克隆專案

```bash
git clone https://github.com/jasontsaicc/eks-terraform-karpenter.git
cd eks-terraform-karpenter
```

### Step 2: 配置參數

編輯 `terraform.tfvars`:

```hcl
# 基本配置
project_name = "eks-gitops"
environment  = "test"
region       = "ap-northeast-1"

# 網路配置
vpc_cidr = "10.0.0.0/16"
azs      = ["ap-northeast-1a", "ap-northeast-1c"]

# 節點配置
node_instance_types = ["t3.medium"]
node_capacity_type  = "SPOT"  # 成本優化
```

### Step 3: 初始化 Terraform Backend

```bash
# 建立 S3 Backend
cd terraform-backend
terraform init
terraform apply

# 記錄輸出的 S3 bucket 名稱
export BACKEND_BUCKET=$(terraform output -raw s3_bucket_name)
cd ..
```

### Step 4: 部署 EKS 集群

```bash
# 初始化 Terraform
terraform init

# 檢查部署計劃
terraform plan

# 執行部署 (約需 15-20 分鐘)
terraform apply -auto-approve

# 配置 kubectl
aws eks update-kubeconfig --region ap-northeast-1 --name $(terraform output -raw cluster_name)

# 驗證連接
kubectl get nodes
```

### Step 5: 安裝核心元件

```bash
# 方法 1: 使用自動部署腳本
chmod +x scripts/deploy-all.sh
./scripts/deploy-all.sh

# 方法 2: 手動逐步安裝
```

#### 5.1 安裝 AWS Load Balancer Controller

```bash
# 安裝 cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# 等待 cert-manager 就緒
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=120s

# 安裝 ALB Controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$(terraform output -raw cluster_name) \
  --set serviceAccount.create=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw aws_load_balancer_controller_role_arn)
```

#### 5.2 安裝 Karpenter

```bash
# 創建 namespace
kubectl create namespace karpenter

# 安裝 Karpenter
helm repo add karpenter https://karpenter.sh/charts
helm repo update

helm install karpenter karpenter/karpenter \
  --namespace karpenter \
  --version v0.35.0 \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw karpenter_controller_role_arn) \
  --set settings.clusterName=$(terraform output -raw cluster_name)

# 應用 Provisioners
kubectl apply -f karpenter/provisioners.yaml
```

#### 5.3 安裝 ArgoCD

```bash
# 創建 namespace
kubectl create namespace argocd

# 安裝 ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 5.51.6 \
  -f argocd/values.yaml

# 獲取初始密碼
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

#### 5.4 安裝 GitLab (可選)

```bash
# 創建 namespace
kubectl create namespace gitlab

# 安裝 GitLab
helm repo add gitlab https://charts.gitlab.io
helm repo update

helm install gitlab gitlab/gitlab \
  --namespace gitlab \
  --version 7.11.0 \
  -f gitlab/values.yaml \
  --timeout 600s
```

### Step 6: 配置 DNS 和 SSL

1. **創建 ACM 證書**:
```bash
aws acm request-certificate \
  --domain-name "*.example.com" \
  --validation-method DNS \
  --region ap-northeast-1
```

2. **配置 Route53**:
```bash
# 獲取 ALB DNS
kubectl get ingress -A

# 在 Route53 創建 CNAME 記錄指向 ALB
```

## 服務配置

### ArgoCD 配置

1. **訪問 UI**:
```bash
# Port forwarding
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 訪問 https://localhost:8080
# 用戶名: admin
# 密碼: 使用上面獲取的初始密碼
```

2. **添加 Git Repository**:
```bash
argocd repo add https://github.com/jasontsaicc/eks-terraform-karpenter.git \
  --username YOUR_USERNAME \
  --password YOUR_TOKEN
```

3. **創建應用**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/jasontsaicc/my-app
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### GitLab 配置

1. **獲取 root 密碼**:
```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab \
  -o jsonpath='{.data.password}' | base64 -d
```

2. **配置 Runner**:
```bash
# 獲取 registration token
kubectl get secret gitlab-gitlab-runner-secret \
  -n gitlab \
  -o jsonpath='{.data.runner-registration-token}' | base64 -d
```

### Karpenter 節點池配置

```yaml
# 修改 karpenter/provisioners.yaml
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: spot-compute
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3.large"]
  limits:
    cpu: "1000"
    memory: "1000Gi"
```

## 日常操作

### 擴展節點

```bash
# 手動擴展
kubectl scale deployment my-app --replicas=10

# Karpenter 會自動創建新節點
kubectl get nodes -w
```

### 更新應用

```bash
# 通過 ArgoCD
argocd app sync my-app

# 或直接 kubectl
kubectl set image deployment/my-app app=myimage:v2
```

### 監控和日誌

```bash
# 訪問 Grafana
kubectl port-forward svc/monitoring-grafana -n monitoring 3000:80
# 用戶名: admin, 密碼: changeme

# 查看日誌
kubectl logs -f deployment/my-app

# 查看指標
kubectl top nodes
kubectl top pods
```

## 成本優化

### 1. 使用 Spot 實例

```bash
# 配置 Karpenter 優先使用 Spot
kubectl edit nodepool general-purpose
# 設置 capacity-type: ["spot", "on-demand"]
```

### 2. 自動縮放配置

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

### 3. 定時關閉非生產環境

```bash
# 創建 CronJob 關閉節點
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-down
spec:
  schedule: "0 19 * * 1-5"  # 週一至週五 19:00
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: kubectl
            image: bitnami/kubectl
            command:
            - /bin/sh
            - -c
            - kubectl scale deployment --all --replicas=0 -n default
          restartPolicy: OnFailure
EOF
```

### 4. 成本監控

```bash
# 使用 AWS Cost Explorer API
aws ce get-cost-and-usage \
  --time-period Start=2024-01-01,End=2024-01-31 \
  --granularity MONTHLY \
  --metrics "BlendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE
```

## 故障處理

### 常見問題解決

1. **節點無法加入集群**
```bash
# 檢查 IAM 角色
aws iam get-role --role-name $(terraform output -raw node_group_iam_role_name)

# 檢查安全組
aws ec2 describe-security-groups --group-ids $(terraform output -raw cluster_security_group_id)
```

2. **Pod 無法啟動**
```bash
# 檢查事件
kubectl describe pod POD_NAME

# 檢查日誌
kubectl logs POD_NAME --previous
```

3. **ALB 無法創建**
```bash
# 檢查 ALB Controller 日誌
kubectl logs -n kube-system deployment/aws-load-balancer-controller

# 檢查 IAM 權限
aws iam simulate-principal-policy \
  --policy-source-arn $(terraform output -raw aws_load_balancer_controller_role_arn) \
  --action-names elasticloadbalancing:CreateLoadBalancer
```

## 清理資源

### 完整清理

```bash
# 使用清理腳本
chmod +x scripts/cleanup-all.sh
./scripts/cleanup-all.sh
```

### 手動清理步驟

```bash
# 1. 刪除所有 Kubernetes 資源
kubectl delete ingress --all --all-namespaces
kubectl delete svc --all --all-namespaces

# 2. 卸載 Helm charts
helm list -A | awk 'NR>1 {print "helm uninstall " $1 " -n " $2}' | bash

# 3. 刪除 Karpenter 節點
kubectl delete nodepools --all -n karpenter
kubectl delete ec2nodeclasses --all -n karpenter

# 4. 銷毀 Terraform 資源
terraform destroy -auto-approve

# 5. 清理 Backend
cd terraform-backend
terraform destroy -auto-approve
```

## 最佳實踐

### 安全性

1. **最小權限原則**
   - 使用 IRSA 為每個服務創建獨立 IAM 角色
   - 實施 NetworkPolicy 限制 Pod 間通信

2. **密鑰管理**
   - 使用 AWS Secrets Manager 存儲敏感資訊
   - 啟用 EKS 密鑰加密

3. **網路隔離**
   - 私有子網部署工作負載
   - 使用 Security Groups 控制流量

### 可靠性

1. **多 AZ 部署**
2. **自動故障恢復**
3. **定期備份**

### 效能優化

1. **資源限制設置**
2. **快取策略**
3. **CDN 整合**

## 支援與貢獻

- **問題回報**: [GitHub Issues](https://github.com/jasontsaicc/eks-terraform-karpenter/issues)
- **貢獻指南**: 歡迎提交 PR
- **作者**: jasontsai

## 授權

MIT License

---

**最後更新**: 2024-08  
**版本**: 1.0.0