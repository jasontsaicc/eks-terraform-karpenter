# 🚀 EKS + Karpenter v1.6.2 完整解決方案

## 📖 概述

這個項目提供了完整的 AWS EKS + Karpenter v1.6.2 部署解決方案，包含自動化腳本、成本監控和完整的清理機制。

---

## 🎯 目標狀態

### ✅ 已解決的問題
- **Karpenter 升級到 v1.6.2** - 修復所有兼容性問題  
- **AWS Load Balancer Controller 錯誤** - 完全修復區域配置問題
- **kubeconfig 衝突** - 自動處理 K3s vs EKS 衝突
- **IAM 角色配置** - 完整的權限配置
- **資源標記** - 正確的 Karpenter 發現標記

### 🏗️ 部署的基礎設施
- **EKS 集群**: v1.30, 2個工作節點
- **VPC**: 3個 AZ，私有/公有子網路
- **NAT Gateway**: 單一實例 (成本優化)
- **Karpenter**: v1.6.2 (支援 Spot 實例)  
- **AWS Load Balancer Controller**: v2.13.4
- **IAM 角色**: 完整權限配置

---

## 🚀 快速開始

### 方法 1: 自動化部署 (推薦)
```bash
cd /home/ubuntu/projects/aws_eks_terraform
./scripts/auto-deploy.sh
```

### 方法 2: 手動步驟
```bash
# 1. 部署基礎設施
terraform init
terraform apply

# 2. 配置 kubectl  
export KUBECONFIG=~/.kube/config
aws eks update-kubeconfig --region ap-southeast-1 --name eks-lab-test-eks

# 3. 安裝 Karpenter
./scripts/setup-karpenter-v162.sh

# 4. 驗證部署
./scripts/validate-deployment.sh
```

---

## 📁 文件結構

```
aws_eks_terraform/
├── 📄 COMPLETE_DEPLOYMENT_GUIDE.md    # 完整部署手冊
├── 📄 README_DEPLOYMENT.md            # 本文件
├── 📄 main.tf                        # Terraform 主配置
├── 📄 variables.tf                   # Terraform 變數
├── 📄 karpenter-nodepool-v162.yaml   # Karpenter v1.6.2 配置
├── 📄 simple-test.yaml               # 簡單測試部署
├── 📁 scripts/                       # 自動化腳本
│   ├── 🔧 auto-deploy.sh             # 一鍵自動部署  
│   ├── 🔧 setup-karpenter-v162.sh    # Karpenter 安裝腳本
│   ├── 🔧 validate-deployment.sh     # 部署驗證腳本
│   ├── 🔧 test-karpenter-comprehensive.sh # 完整功能測試
│   ├── 🔧 cost-monitor.sh            # 成本監控腳本
│   └── 🔧 cleanup-complete.sh        # 完整清理腳本
├── 📁 modules/                       # Terraform 模組
│   ├── vpc/                          # VPC 模組
│   └── iam/                          # IAM 模組
└── 📄 terraform-state-backup.txt     # Terraform 狀態備份
```

---

## 🔧 可用腳本

| 腳本 | 功能 | 用途 |
|------|------|------|
| `auto-deploy.sh` | 🚀 一鍵自動部署 | 從零開始完整部署 |
| `setup-karpenter-v162.sh` | 📦 Karpenter 安裝 | 安裝/升級 Karpenter v1.6.2 |
| `validate-deployment.sh` | ✅ 部署驗證 | 23項全面檢查 |
| `test-karpenter-comprehensive.sh` | 🧪 功能測試 | 完整功能驗證 |
| `cost-monitor.sh` | 💰 成本監控 | 即時成本分析 |
| `cleanup-complete.sh` | 🧹 完整清理 | 刪除所有 AWS 資源 |

---

## 💰 成本資訊

### 每日預估成本 (ap-southeast-1)
```
固定成本:
• EKS 控制平面: $2.40/day
• NAT Gateway: $1.08/day  
• 小計: $3.48/day

變動成本:
• EC2 實例 (2×t3.medium): ~$1.20/day (Spot)
• EBS 存儲: ~$0.50/day
• Load Balancer: ~$0.54/day

總計: ~$5.72/day (~$172/month)
```

### 💡 成本優化
- ✅ 優先使用 Spot 實例 (節省 70%)
- ✅ Karpenter 自動縮放
- ✅ 單一 NAT Gateway
- ✅ 整合策略: `WhenEmptyOrUnderutilized`

---

## 🔍 驗證檢查清單

部署成功後應該看到:

### ✅ 基礎設施
- [ ] EKS 集群狀態: ACTIVE
- [ ] 節點數量: 2個 (Ready)
- [ ] VPC ID: vpc-xxxxxx
- [ ] 所有子網路已標記

### ✅ 應用程式
- [ ] Karpenter: 1/1 Running (v1.6.2)
- [ ] AWS LBC: 2/2 Running (v2.13.4)  
- [ ] NodePool: Ready
- [ ] EC2NodeClass: Ready

### ✅ 功能測試
- [ ] 可以創建 Pod
- [ ] Karpenter 自動配置節點
- [ ] Spot 實例正常工作
- [ ] 成本監控正常

---

## 🚨 故障排除

### 問題 1: Karpenter CrashLoopBackOff
**解決方案:**
```bash
kubectl patch deployment karpenter -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"controller","env":[{"name":"AWS_REGION","value":"ap-southeast-1"}]}]}}}}'
```

### 問題 2: kubeconfig 衝突
**解決方案:**
```bash
# 使用 EKS
export KUBECONFIG=~/.kube/config

# 使用 K3s  
unset KUBECONFIG
```

### 問題 3: AWS LBC 初始化失敗
**解決方案:**
```bash
VPC_ID=$(aws eks describe-cluster --name eks-lab-test-eks --region ap-southeast-1 --query "cluster.resourcesVpcConfig.vpcId" --output text)
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set vpcId=$VPC_ID --set region=ap-southeast-1
```

---

## 🔄 重建流程

### 完全重建 (推薦)
```bash
# 1. 清理現有資源
./scripts/cleanup-complete.sh

# 2. 等待清理完成 (5-10分鐘)

# 3. 重新部署
./scripts/auto-deploy.sh
```

### 部分重建
```bash
# 只重新安裝 Karpenter
./scripts/setup-karpenter-v162.sh

# 只驗證部署
./scripts/validate-deployment.sh
```

---

## 📊 監控和維護

### 日常檢查
```bash
# 成本監控
./scripts/cost-monitor.sh

# 健康檢查
./scripts/validate-deployment.sh

# 功能測試
kubectl apply -f simple-test.yaml
```

### 定期維護
- **每週**: 執行功能測試
- **每月**: 檢查成本優化機會
- **季度**: 升級 Karpenter 和相關元件

---

## 🧹 清理資源

### 完整清理 (節省成本)
```bash
./scripts/cleanup-complete.sh
```

**清理內容:**
- ✅ EKS 集群和節點
- ✅ VPC、子網路、路由表  
- ✅ NAT Gateway、Internet Gateway
- ✅ IAM 角色和政策
- ✅ Load Balancer 和 Target Groups
- ✅ 安全群組和 EBS 卷
- ✅ CloudWatch 日誌群組
- ✅ SQS 佇列

**預期節省**: ~$5.72/day

---

## 🔗 相關資源

- **Karpenter 官方文檔**: https://karpenter.sh/v1.6/
- **AWS EKS 用戶指南**: https://docs.aws.amazon.com/eks/
- **Terraform AWS Provider**: https://registry.terraform.io/providers/hashicorp/aws

---

## 📞 支援

如遇問題，請檢查:

1. **日誌**: `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter`
2. **驗證**: `./scripts/validate-deployment.sh`  
3. **成本**: `./scripts/cost-monitor.sh`
4. **手冊**: `COMPLETE_DEPLOYMENT_GUIDE.md`

---

*最後更新: 2025-08-26*  
*版本: v1.6.2-stable*  
*狀態: ✅ 生產就緒*