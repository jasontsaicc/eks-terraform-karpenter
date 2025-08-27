# Karpenter 成本優化實施總結

## 專案狀態
- ✅ 架構設計完成
- ✅ 配置文件準備完成
- ✅ 部署腳本準備完成
- ⏳ 待實際部署測試

## 已完成的準備工作

### 1. 架構設計文檔
- **文件**: `KARPENTER_COST_OPTIMIZATION_ARCHITECTURE.md`
- **內容**: 完整的成本優化架構設計，包含節點分配策略和成本預估

### 2. Terraform 配置
- **文件**: `terraform-optimized.tfvars`
- **特點**:
  - 系統節點使用最小規格 t3.small
  - 配置 taints 防止應用 Pod 調度到系統節點
  - 啟用 Karpenter 支援

### 3. Karpenter 配置
- **文件**: `k8s-manifests/karpenter-provisioner.yaml`
- **包含**:
  - 應用節點 Provisioner（優先 SPOT）
  - GitLab Runner 專用 Provisioner
  - 30 秒空閒自動刪除節點

### 4. 時間排程
- **文件**: `k8s-manifests/karpenter-scheduler.yaml`
- **排程**:
  - 工作日 19:00 UTC 縮減
  - 工作日 08:00 UTC 擴展
  - 週五 20:00 UTC 週末關閉
  - 週一 08:00 UTC 週末啟動

### 5. 應用配置
- **GitLab**: `k8s-manifests/gitlab-karpenter.yaml`
  - 配置使用 Karpenter 應用節點
  - GitLab Runner 使用專用節點池
  
- **ArgoCD**: `k8s-manifests/argocd-karpenter.yaml`
  - 所有組件使用應用節點
  - 配置 HPA 自動擴展

### 6. 部署腳本
- `scripts/deploy-optimized-eks.sh` - 部署優化的 EKS
- `scripts/deploy-step-by-step.sh` - 分步部署
- `scripts/setup-karpenter.sh` - 安裝 Karpenter
- `scripts/deploy-karpenter-setup.sh` - 完整部署
- `scripts/test-karpenter-scaling.sh` - 完整測試
- `scripts/quick-test-karpenter.sh` - 快速測試
- `scripts/monitor-costs.sh` - 成本監控

## 成本優化策略

### 1. 節點分離
- **系統節點**: 24/7 運行，最小規格
- **應用節點**: 按需創建，自動刪除

### 2. SPOT 實例
- 優先使用 SPOT 節省 70% 成本
- On-Demand 作為備用

### 3. 時間排程
- 下班時間自動縮減
- 週末完全關閉應用節點

### 4. 快速縮容
- 30 秒空閒即刪除節點
- 避免空閒資源浪費

## 預期成本節省

### 傳統架構（24/7）
- 2 x t3.medium: $60/月
- EKS: $72/月
- NAT: $45/月
- **總計: $177/月**

### 優化架構
- 1 x t3.small: $15/月
- Karpenter SPOT: $12/月
- EKS: $72/月
- NAT: $45/月
- **總計: $144/月**
- **節省: 20-30%**

## 部署步驟

### 選項 1: 完整自動部署
```bash
chmod +x /home/ubuntu/projects/aws_eks_terraform/scripts/*.sh
./scripts/deploy-karpenter-setup.sh
```

### 選項 2: 分步部署
```bash
# Step 1: 部署基礎設施
./scripts/deploy-step-by-step.sh

# Step 2: 安裝 Karpenter
./scripts/setup-karpenter.sh

# Step 3: 測試
./scripts/quick-test-karpenter.sh
```

## 測試驗證

### 功能測試
```bash
# 測試自動擴縮容
./scripts/test-karpenter-scaling.sh

# 快速測試
./scripts/quick-test-karpenter.sh
```

### 成本監控
```bash
# 查看成本報告
./scripts/monitor-costs.sh
```

## 注意事項

1. **首次部署延遲**: 第一個節點創建需要 2-3 分鐘
2. **SPOT 中斷**: 可能發生但機率低，有 On-Demand 備用
3. **時區設置**: CronJob 使用 UTC 時間，需根據實際調整
4. **GitLab 資源**: GitLab 需要較多資源，建議根據實際需求調整

## 故障排除

### 節點未創建
```bash
# 檢查 Karpenter 日誌
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# 檢查 Provisioner
kubectl describe provisioner application-nodes
```

### Pod 無法調度
```bash
# 檢查節點 taints
kubectl describe nodes

# 檢查 Pod tolerations
kubectl describe pod <pod-name>
```

### 成本未降低
```bash
# 檢查節點類型
kubectl get nodes -L karpenter.sh/capacity-type

# 確認時間排程運行
kubectl get cronjobs -n karpenter
```

## 總結

此架構通過以下方式實現成本優化：
1. ✅ 最小化系統節點規格
2. ✅ 動態管理應用節點
3. ✅ 優先使用 SPOT 實例
4. ✅ 時間排程自動縮容
5. ✅ 快速釋放空閒資源

預計可節省 20-30% 的運營成本，同時保持服務的靈活性和可用性。

---
作者: jasontsai
日期: 2025-08-25