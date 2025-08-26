# NodeGroup 建立失敗分析報告

## 問題診斷

### 失敗原因
NodeGroup `general` 建立失敗的主要原因：

1. **網路配置問題** ⚠️
   - **根本原因**: 私有子網路由表缺少到 NAT Gateway 的路由
   - **影響**: EC2 實例無法訪問互聯網
   - **結果**: 節點無法下載必要的 Kubernetes 組件和加入集群

2. **失敗詳情**
   ```json
   {
     "code": "NodeCreationFailure",
     "message": "Instances failed to join the kubernetes cluster",
     "resourceIds": ["i-0d2af1edabfbae72a", "i-0f5cb20ac4b45e0fd"]
   }
   ```

3. **SPOT 實例影響**
   - NodeGroup 使用 SPOT 實例（節省成本）
   - 但 SPOT **不是**失敗原因
   - 實例已成功啟動，問題在於網路連接

## 已執行的修復措施

### 1. 修復網路路由
```bash
# 添加 NAT Gateway 路由到私有子網路由表
aws ec2 create-route \
  --route-table-id rtb-03df804ba96e83dca \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id nat-0af4d782f27ab03c5 \
  --region ap-southeast-1
```

### 2. 重新創建 NodeGroup
- 刪除失敗的 `general` NodeGroup
- 創建新的 `system` NodeGroup
- 配置變更：
  - 名稱: system
  - 實例類型: t3.small（更經濟）
  - 容量類型: ON_DEMAND（確保穩定性）
  - 數量: 2-3 個節點

## 當前狀態

### 新 NodeGroup 配置
- **名稱**: system
- **狀態**: CREATING（創建中）
- **實例類型**: t3.small
- **容量類型**: ON_DEMAND
- **節點數**: 2（最小）到 3（最大）
- **磁碟大小**: 20 GB

### 預期結果
- 節點將在 5-10 分鐘內成功加入集群
- 所有 Pod 將能正常調度和運行

## 成本影響

### 原配置（失敗）
- 2 x t3.medium SPOT: ~$18/月

### 新配置（穩定）
- 2 x t3.small ON_DEMAND: ~$30/月
- 略微增加成本但確保穩定性

## 驗證步驟

創建完成後執行：

```bash
# 1. 檢查節點狀態
kubectl get nodes

# 2. 檢查 Pod 狀態
kubectl get pods -A

# 3. 驗證網路連接
kubectl run test-pod --image=busybox --rm -it --restart=Never -- wget -O- http://www.google.com

# 4. 檢查節點日誌
kubectl get events -n kube-system
```

## 經驗教訓

1. **Terraform 模組問題**
   - VPC 模組未正確配置私有子網的 NAT Gateway 路由
   - 需要手動添加路由規則

2. **網路驗證重要性**
   - 部署前應驗證所有子網的路由配置
   - 私有子網必須有到 NAT Gateway 的路由

3. **SPOT vs ON_DEMAND**
   - 系統關鍵節點建議使用 ON_DEMAND
   - 應用節點可以使用 SPOT（配合 Karpenter）

## 建議

1. **短期**
   - 等待新 NodeGroup 創建完成
   - 驗證所有服務正常運行

2. **長期**
   - 修復 Terraform VPC 模組配置
   - 實施 Karpenter 管理應用節點
   - 系統節點保持 ON_DEMAND 確保穩定

---
報告生成時間: 2025-08-25 22:08 UTC
作者: jasontsai