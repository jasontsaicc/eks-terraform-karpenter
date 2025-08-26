# 📋 Karpenter 功能測試手冊

## 📖 概述

本手冊提供完整的 Karpenter v1.6.2 功能測試指南，確保自動節點擴縮容功能正常運作。

---

## 🎯 測試目標

驗證 Karpenter 的以下核心功能：
1. **節點自動擴容** - 根據工作負載需求自動增加節點
2. **節點自動縮容** - 移除不需要的節點以節省成本
3. **Spot 實例支援** - 優先使用低成本的 Spot 實例
4. **智能實例選擇** - 根據工作負載選擇最適合的實例類型
5. **整合策略** - 自動整合和優化節點配置

---

## 🛠️ 前置條件

### 必要組件
- ✅ EKS 集群正常運行
- ✅ Karpenter v1.6.2 已安裝並運行
- ✅ NodePool 和 EC2NodeClass 已配置
- ✅ IAM 角色和權限正確設置
- ✅ kubectl 配置指向正確的 EKS 集群

### 環境確認
```bash
# 1. 確認連接到正確的集群
kubectl config current-context

# 2. 檢查 Karpenter 狀態
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# 3. 檢查 NodePool 配置
kubectl get nodepools -A
kubectl get ec2nodeclasses -A
```

---

## 🧪 測試方法

### 方法 1: 自動化測試腳本 (推薦)

```bash
# 執行完整的自動化測試
cd /home/ubuntu/projects/aws_eks_terraform
./scripts/test-karpenter-comprehensive.sh
```

### 方法 2: 手動測試步驟

#### 測試 1: 節點擴容測試

1. **記錄初始狀態**
   ```bash
   kubectl get nodes
   kubectl get nodeclaims
   ```

2. **創建高資源需求的工作負載**
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: scale-test
   spec:
     replicas: 4
     selector:
       matchLabels:
         app: scale-test
     template:
       metadata:
         labels:
           app: scale-test
       spec:
         containers:
         - name: consumer
           image: nginx:alpine
           resources:
             requests:
               cpu: "900m"
               memory: "512Mi"
   EOF
   ```

3. **觀察 Karpenter 反應**
   ```bash
   # 觀察 NodeClaim 創建
   watch kubectl get nodeclaims
   
   # 查看 Karpenter 日誌
   kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
   ```

4. **驗證結果**
   - ✅ 應該看到新的 NodeClaim 被創建
   - ✅ NodeClaim 狀態應該是 spot 或 on-demand
   - ✅ 實例類型應該適合工作負載需求

#### 測試 2: 節點縮容測試

1. **移除工作負載**
   ```bash
   kubectl delete deployment scale-test
   ```

2. **觀察整合過程**
   ```bash
   # 等待整合策略生效 (默認 30 秒後開始)
   watch kubectl get nodeclaims
   ```

3. **驗證結果**
   - ✅ 不需要的 NodeClaim 應該被標記為終止
   - ✅ EC2 實例應該被終止
   - ✅ 節點數量回到基線

#### 測試 3: Spot 實例測試

1. **檢查實例類型**
   ```bash
   kubectl get nodeclaims -o jsonpath='{.items[*].status.capacity.capacity-type}'
   ```

2. **驗證結果**
   - ✅ 應該看到 "spot" 實例被優先選擇
   - ✅ 成本效益最大化

#### 測試 4: 多實例類型選擇測試

1. **創建不同資源需求的工作負載**
   ```bash
   # 創建小型工作負載
   kubectl run small-pod --image=nginx --requests='cpu=100m,memory=128Mi'
   
   # 創建大型工作負載
   kubectl run large-pod --image=nginx --requests='cpu=2000m,memory=4Gi'
   ```

2. **驗證結果**
   - ✅ Karpenter 應該選擇不同的實例類型
   - ✅ 實例類型應該匹配工作負載需求

---

## 📊 測試結果評估

### 成功標準

| 測試項目 | 預期結果 | 驗證方式 |
|----------|----------|----------|
| 節點擴容 | 在 60 秒內創建 NodeClaim | `kubectl get nodeclaims` |
| 節點縮容 | 在 90 秒內開始終止未使用的節點 | 觀察 NodeClaim 狀態變化 |
| Spot 實例 | 優先使用 Spot 實例 | 檢查 capacity-type |
| 實例選擇 | 選擇適合的實例類型 | 檢查 instance-type |
| 整合策略 | 正確應用整合政策 | 檢查 NodePool 配置 |

### 常見問題排除

#### 問題 1: NodeClaim 未創建
**原因:** 
- 資源要求不足以觸發擴容
- NodePool 配置錯誤
- IAM 權限不足

**解決方案:**
```bash
# 檢查 NodePool 狀態
kubectl describe nodepool general-purpose

# 檢查 Karpenter 日誌
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter
```

#### 問題 2: 節點未加入集群
**原因:**
- 用戶數據腳本錯誤
- 網路配置問題
- 安全群組限制

**解決方案:**
```bash
# 檢查 EC2 實例狀態
aws ec2 describe-instances --instance-ids <instance-id>

# 檢查安全群組配置
kubectl describe ec2nodeclass default
```

#### 問題 3: 縮容不生效
**原因:**
- 整合策略配置不當
- 節點上有不可驅逐的 Pod
- 整合時間未到

**解決方案:**
```bash
# 檢查整合策略
kubectl get nodepool general-purpose -o yaml | grep -A5 disruption

# 檢查節點上的 Pod
kubectl describe node <node-name>
```

---

## 🔧 高級測試場景

### 測試場景 1: 混合工作負載
創建包含不同資源需求的混合工作負載，測試 Karpenter 的智能調度能力。

### 測試場景 2: 突發流量處理
模擬突發流量，測試 Karpenter 的快速擴容能力。

### 測試場景 3: 成本優化驗證
比較使用 Karpenter 前後的成本差異，驗證成本優化效果。

---

## 📈 性能基準

### 擴容性能
- **NodeClaim 創建時間**: < 60 秒
- **節點就緒時間**: < 5 分鐘
- **Pod 調度時間**: < 30 秒

### 縮容性能  
- **整合觸發時間**: 30 秒（可配置）
- **節點終止時間**: < 90 秒
- **資源清理時間**: < 120 秒

---

## 📝 測試報告範本

```
Karpenter 功能測試報告
====================

測試日期: [日期]
測試環境: EKS v1.30 + Karpenter v1.6.2
測試執行者: [姓名]

測試結果:
□ 節點擴容: PASS/FAIL
□ 節點縮容: PASS/FAIL  
□ Spot 實例: PASS/FAIL
□ 實例選擇: PASS/FAIL
□ 整合策略: PASS/FAIL

問題記錄:
- [記錄任何發現的問題]

建議優化:
- [記錄改進建議]

總體評估: PASS/FAIL
```

---

## 🔄 定期測試建議

### 測試頻率
- **開發環境**: 每次部署後
- **測試環境**: 每週一次
- **生產環境**: 每月一次

### 監控指標
- 節點數量變化
- 資源利用率
- 成本變化
- 響應時間

---

## 📞 故障排除支援

### 診斷命令
```bash
# Karpenter 健康檢查
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50

# NodePool 狀態檢查
kubectl get nodepools -o wide
kubectl describe nodepool general-purpose

# NodeClaim 狀態檢查
kubectl get nodeclaims -o wide
kubectl describe nodeclaim <nodeclaim-name>

# 節點狀態檢查
kubectl get nodes -o wide
kubectl describe node <node-name>
```

### 重要日誌位置
- **Karpenter 日誌**: `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter`
- **節點日誌**: `/var/log/cloud-init-output.log`（在節點上）
- **EKS 事件**: `kubectl get events --sort-by=.metadata.creationTimestamp`

---

*最後更新: 2025-08-26*  
*版本: v1.6.2-comprehensive*  
*狀態: ✅ 已驗證*