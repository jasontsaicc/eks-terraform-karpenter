# AWS EKS Terraform 基礎設施

這是一個完整的 AWS EKS 集群 Terraform 配置，已成功部署並測試，包含完整的運維腳本和文檔。

## 📊 當前狀態
- ✅ **EKS v1.30** - 2節點集群運行正常  
- ✅ **AWS Load Balancer Controller** - 負載均衡正常  
- ✅ **Metrics Server** - 資源監控正常  
- 🟡 **Karpenter** - 需要配置調整  
- 📚 **完整文檔** - 490行部署指南和狀態報告  

## 🗂️ 項目結構
```
📁 configs/current/          # 當前配置文件
📁 docs/current/            # 最新文檔 (部署指南 + 狀態報告)
📁 scripts/                 # 運維腳本
📁 modules/                 # Terraform 模組
📁 tests/current/           # 測試文件
📁 archived/                # 歷史歸檔
```

詳細結構請參考: [PROJECT-STRUCTURE.md](./PROJECT-STRUCTURE.md)

## 🏗️ 架構概覽

```
┌─────────────────────────────────────────────────────────────┐
│                          VPC (10.0.0.0/16)                 │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │  Public Subnet  │  │  Public Subnet  │  │Public Subnet │ │
│  │   (10.0.1.0/24) │  │   (10.0.2.0/24) │  │(10.0.3.0/24) │ │
│  │                 │  │                 │  │              │ │
│  │  ┌─────────────┐│  │  ┌─────────────┐│  │              │ │
│  │  │     NAT     ││  │  │Load Balancer││  │              │ │
│  │  │   Gateway   ││  │  │             ││  │              │ │
│  │  └─────────────┘│  │  └─────────────┘│  │              │ │
│  └─────────────────┘  └─────────────────┘  └──────────────┘ │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │ Private Subnet  │  │ Private Subnet  │  │Private Subnet│ │
│  │  (10.0.11.0/24) │  │  (10.0.12.0/24) │  │(10.0.13.0/24)│ │
│  │                 │  │                 │  │              │ │
│  │  ┌─────────────┐│  │  ┌─────────────┐│  │ ┌──────────┐ │ │
│  │  │EKS Node     ││  │  │EKS Node     ││  │ │EKS Node  │ │ │
│  │  │Group        ││  │  │Group        ││  │ │Group     │ │ │
│  │  └─────────────┘│  │  └─────────────┘│  │ └──────────┘ │ │
│  └─────────────────┘  └─────────────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## 📋 功能特點

### 🔧 核心基礎設施
- **VPC**: 多 AZ 網路架構，公私有子網路分離
- **EKS**: Kubernetes 1.30，支援多種 Add-ons
- **IAM**: IRSA 支援，最小權限原則
- **安全**: 端到端加密，網路隔離

### 💰 成本優化
- **Spot 實例**: 節省 60-90% 計算成本
- **單一 NAT Gateway**: 節省網路成本
- **GP3 儲存**: 更佳的性價比
- **自動關機**: 非工作時間節省成本

### 🚀 擴展性支援
- **Karpenter**: 智能節點自動調節
- **Cluster Autoscaler**: 基於工作負載自動擴展
- **HPA**: 水平 Pod 自動縮放
- **多節點群組**: 支援不同工作負載

## 🛠️ 前置需求

### 軟體需求
```bash
# 必需工具
- Terraform >= 1.5.0
- AWS CLI >= 2.0
- kubectl >= 1.28
- helm >= 3.12

# 可選工具
- k9s (Kubernetes 管理)
- kubectx/kubens (上下文切換)
- stern (日誌查看)
```

### AWS 權限需求
確保您的 AWS 使用者或角色具備以下權限：
- EC2 (VPC, 安全群組, 實例管理)
- EKS (集群和節點群組管理)
- IAM (角色和政策管理)
- CloudWatch (日誌和監控)
- Route53 (DNS 解析)

## 🚀 快速開始

### 方法1: 一鍵部署 (推薦)
```bash
# 使用自動化腳本一鍵部署
./quick-deploy.sh
```

### 方法2: 手動部署
```bash
# 1. 配置環境
cp configs/current/terraform.tfvars.simple configs/current/terraform.tfvars
vi configs/current/terraform.tfvars  # 編輯配置

# 2. 初始化和部署
terraform init -backend-config=configs/current/backend-config.hcl
terraform apply -auto-approve

# 3. 配置 kubectl
aws eks update-kubeconfig --region ap-southeast-1 --name eks-lab-test-eks
export KUBECONFIG=~/.kube/config-eks
```

### 📚 詳細指南
完整部署步驟請參考: [`docs/current/EKS-DEPLOYMENT-GUIDE.md`](docs/current/EKS-DEPLOYMENT-GUIDE.md)  
系統狀態報告請參考: [`docs/current/SYSTEM-STATUS-REPORT.md`](docs/current/SYSTEM-STATUS-REPORT.md)

## 🔧 附加元件安裝

使用互動式腳本安裝附加元件：
```bash
./scripts/setup-addons.sh
```

### 可用附加元件
1. **ArgoCD** - GitOps 持續部署
2. **GitLab Runner** - CI/CD 執行器
3. **Karpenter** - 智能節點調節
4. **Prometheus + Grafana** - 監控和視覺化
5. **NGINX Ingress** - 流量路由

## 📊 模組架構

```
modules/
├── vpc/           # VPC 和網路資源
├── eks/           # EKS 集群和節點群組
├── iam/           # IAM 角色和政策
└── security/      # 安全群組和政策

environments/
└── test/          # 測試環境配置

scripts/
├── deploy.sh      # 自動化部署
├── destroy.sh     # 資源清理
└── setup-addons.sh# 附加元件安裝
```

## 🔒 安全最佳實踐

### 網路安全
- 所有節點部署在私有子網路
- 使用安全群組限制流量
- 啟用 VPC Flow Logs（可選）

### 身份驗證
- 使用 IRSA 進行服務帳戶認證
- 實施最小權限原則
- 啟用 EKS 審計日誌

### 資料保護
- EKS Secrets 加密
- EBS 磁碟加密
- 傳輸層 TLS 加密

詳細資訊請參考：[security-best-practices.md](./security-best-practices.md)

## 💰 成本管理

### 成本優化策略
- 使用 Spot 實例（節省 60-90%）
- 單一 NAT Gateway（節省 ~$45/月）
- GP3 儲存替代 GP2
- 短期日誌保留

### 預估成本
- **測試環境**: ~$144/月（使用 Spot 實例）
- **生產環境**: ~$300-500/月

詳細分析請參考：[cost-optimization.md](./cost-optimization.md)

## 🎯 使用案例

### GitLab CI/CD 流水線
```yaml
# .gitlab-ci.yml 範例
stages:
  - build
  - test
  - deploy

build:
  stage: build
  tags:
    - eks-runner
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA

deploy:
  stage: deploy
  tags:
    - eks-runner
  script:
    - kubectl set image deployment/app container=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

### ArgoCD 應用程式部署
```yaml
# application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/your-org/your-app
    targetRevision: HEAD
    path: k8s/
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## 🛠️ 運維指南

### 常用命令
```bash
# 檢查集群狀態
kubectl get nodes
kubectl get pods -A

# 查看資源使用情況
kubectl top nodes
kubectl top pods -A

# 檢查 Spot 實例狀態
kubectl describe nodes | grep "spot"

# 監控自動縮放
kubectl describe hpa
```

### 故障排除
```bash
# 檢查 EKS Add-ons 狀態
aws eks describe-addon --cluster-name <cluster-name> --addon-name vpc-cni

# 檢查節點群組狀態
aws eks describe-nodegroup --cluster-name <cluster-name> --nodegroup-name <nodegroup-name>

# 檢查 Auto Scaling Group
aws autoscaling describe-auto-scaling-groups
```

## 🔄 升級和維護

### 集群升級
```bash
# 升級控制平面
aws eks update-cluster-version --name <cluster-name> --version 1.31

# 升級節點群組
aws eks update-nodegroup-version --cluster-name <cluster-name> --nodegroup-name <nodegroup-name>

# 升級 Add-ons
aws eks update-addon --cluster-name <cluster-name> --addon-name vpc-cni --addon-version <version>
```

### 定期維護
- 每月檢查安全更新
- 定期備份重要配置
- 監控成本使用情況
- 檢查 Spot 實例中斷情況

## 🧹 清理資源

```bash
# 標準清理
terraform destroy -auto-approve

# 強制清理 (如果 Terraform 失敗)
./scripts/force-cleanup.sh
```

⚠️ **警告**: 清理操作將刪除所有 AWS 資源，請確保已備份重要資料。  
💡 **提示**: `force-cleanup.sh` 可處理 Terraform 無法清理的資源。

## 🤝 貢獻指南

1. Fork 專案
2. 建立功能分支 (`git checkout -b feature/amazing-feature`)
3. 提交變更 (`git commit -m 'Add amazing feature'`)
4. 推送分支 (`git push origin feature/amazing-feature`)
5. 建立 Pull Request

## 📞 支援與回饋

如果您遇到問題或有改進建議：
1. 檢查現有 Issues
2. 建立新的 Issue 描述問題
3. 提供詳細的錯誤日誌和環境資訊

## 📄 授權條款

此專案採用 MIT 授權條款。詳細資訊請參考 LICENSE 檔案。

---

**注意**: 此配置為測試環境設計。生產環境使用前請進行適當的安全審查和效能測試。