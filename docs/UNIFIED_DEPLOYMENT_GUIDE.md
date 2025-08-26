# AWS EKS 統一部署指南

## 目錄
1. [專案概述](#專案概述)
2. [架構說明](#架構說明)
3. [前置準備](#前置準備)
4. [部署方式](#部署方式)
5. [GitOps 設置](#gitops-設置)
6. [Karpenter 自動擴展](#karpenter-自動擴展)
7. [成本優化](#成本優化)
8. [監控與日誌](#監控與日誌)
9. [故障排除](#故障排除)

## 專案概述

這是一個完整的 AWS EKS Kubernetes 集群部署專案，整合了以下企業級功能：
- 🚀 GitOps (ArgoCD/GitLab)
- ⚡ 自動擴展 (Karpenter)
- 🔄 負載均衡 (AWS Load Balancer Controller)
- 📊 監控系統 (Prometheus/Grafana)
- 💰 成本優化

**Repository**: https://github.com/jasontsaicc/eks-terraform-karpenter

## 架構說明

### 核心組件
- **EKS Cluster**: Kubernetes 1.31 
- **VPC**: 多可用區設計，包含公私有子網
- **Node Groups**: 混合使用 Spot 和 On-Demand 實例
- **Karpenter**: 智能節點自動擴展
- **GitOps**: ArgoCD 或 GitLab 自動化部署

### 網路架構
```
VPC (10.0.0.0/16)
├── Public Subnets (10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24)
├── Private Subnets (10.0.101.0/24, 10.0.102.0/24, 10.0.103.0/24)
└── NAT Gateways (高可用配置)
```

## 前置準備

### 1. 環境要求
```bash
# 安裝必要工具
brew install terraform kubectl helm awscli
```

### 2. AWS 配置
```bash
# 配置 AWS 憑證
aws configure
export AWS_REGION=ap-northeast-1
```

### 3. Terraform 後端設置
```bash
# 初始化 S3 後端儲存
cd terraform-backend
terraform init
terraform apply -auto-approve
cd ..
```

## 部署方式

### 方式一：一鍵部署（推薦）
```bash
# 使用整合腳本部署
./scripts/deploy-all.sh
```

### 方式二：分階段部署
```bash
# 1. 初始化 Terraform
terraform init -backend-config=backend-config.txt

# 2. 部署基礎設施
terraform apply -target=module.vpc -auto-approve
terraform apply -target=module.eks -auto-approve

# 3. 設置附加元件
./scripts/setup-addons.sh

# 4. 部署 Karpenter
./scripts/setup-karpenter.sh
```

### 方式三：手動部署
參考以下步驟逐步執行：

#### 步驟 1: VPC 和網路
```bash
terraform apply -target=module.vpc
```

#### 步驟 2: EKS 集群
```bash
terraform apply -target=module.eks
kubectl get nodes
```

#### 步驟 3: 負載均衡器
```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME}
```

## GitOps 設置

### ArgoCD 部署
```bash
# 安裝 ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f argocd/install.yaml

# 獲取管理員密碼
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# 配置應用程式
kubectl apply -f gitops-apps/argocd-apps.yaml
```

### GitLab Runner 部署
```bash
# 安裝 GitLab Runner
helm repo add gitlab https://charts.gitlab.io
helm install gitlab-runner gitlab/gitlab-runner \
  -f gitlab/runner-values.yaml \
  -n gitlab-runner --create-namespace
```

## Karpenter 自動擴展

### 配置說明
Karpenter 提供智能的節點自動擴展，支援：
- Spot 實例優先策略
- 多實例類型選擇
- 自動節點回收
- 成本優化

### 部署 Karpenter
```bash
# 使用腳本部署
./scripts/setup-karpenter.sh

# 或手動部署
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.0.8 \
  --namespace karpenter \
  --create-namespace \
  --values karpenter/values.yaml
```

### 測試自動擴展
```bash
# 部署測試應用
kubectl apply -f karpenter-test-deployment.yaml

# 觀察節點擴展
kubectl get nodes -w
```

## 成本優化

### 1. Spot 實例策略
- 優先使用 Spot 實例（成本降低 70-90%）
- 自動 fallback 到 On-Demand
- 多實例類型分散風險

### 2. 自動縮容
```yaml
# Karpenter 自動回收閒置節點
ttlSecondsAfterEmpty: 30
consolidationPolicy: WhenUnderutilized
```

### 3. 成本監控
```bash
# 執行成本監控腳本
./scripts/monitor-costs.sh
```

## 監控與日誌

### Prometheus + Grafana
```bash
# 部署監控堆疊
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

### CloudWatch Container Insights
```bash
# 啟用 Container Insights
aws eks update-cluster-config \
  --name ${CLUSTER_NAME} \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

## 故障排除

### 常見問題

#### 1. Karpenter 節點無法加入集群
```bash
# 檢查安全組
aws ec2 describe-security-groups --group-ids ${SG_ID}

# 檢查 IAM 角色
aws iam get-role --role-name KarpenterNodeRole

# 驗證網路連通性
./scripts/verify-network.sh
```

#### 2. Pod 無法調度
```bash
# 檢查節點狀態
kubectl describe nodes

# 檢查 Karpenter 日誌
kubectl logs -n karpenter deployment/karpenter -f
```

#### 3. LoadBalancer 無法創建
```bash
# 檢查 AWS Load Balancer Controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller

# 驗證 IAM 權限
aws iam get-role-policy --role-name eks-aws-load-balancer-controller
```

### 診斷工具
```bash
# 綜合診斷
kubectl get all -A
kubectl top nodes
kubectl top pods -A

# Karpenter 狀態
kubectl get nodepools
kubectl get nodeclaims
```

## 清理資源

### 完整清理
```bash
# 使用清理腳本
./scripts/complete-cleanup.sh
```

### 手動清理
```bash
# 1. 刪除 Kubernetes 資源
kubectl delete -f gitops-apps/
kubectl delete -f k8s-manifests/

# 2. 卸載 Helm charts
helm uninstall karpenter -n karpenter
helm uninstall aws-load-balancer-controller -n kube-system

# 3. 銷毀 Terraform 資源
terraform destroy -auto-approve
```

## 技術支援

如有問題，請參考：
- [AWS EKS 文檔](https://docs.aws.amazon.com/eks/)
- [Karpenter 文檔](https://karpenter.sh/)
- [項目 Issues](https://github.com/jasontsaicc/eks-terraform-karpenter/issues)

---
**最後更新**: 2025-08-25
**維護者**: Jason Tsai