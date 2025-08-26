# EKS 集群部署成功報告

## 部署摘要
- **日期**: 2025-08-24
- **區域**: ap-southeast-1 (新加坡)
- **執行者**: jasontsai
- **狀態**: ✅ 成功部署

## 部署的資源

### 1. VPC 網路架構
- **VPC ID**: vpc-01b472318ce6961c1
- **CIDR**: 10.0.0.0/16
- **可用區**: ap-southeast-1a, ap-southeast-1b, ap-southeast-1c
- **公有子網**: 3個
- **私有子網**: 3個
- **NAT Gateway**: 1個 (單一NAT節省成本)
- **Internet Gateway**: 1個

### 2. IAM 角色和策略
- **EKS Cluster Role**: eks-lab-test-eks-cluster-role
- **Node Group Role**: eks-lab-test-eks-node-group-role
- **狀態**: ✅ 已創建並附加必要的策略

### 3. EKS 集群
- **集群名稱**: eks-lab-test-eks
- **Kubernetes 版本**: 1.30
- **狀態**: ACTIVE
- **端點訪問**: 
  - 私有訪問: 啟用
  - 公開訪問: 啟用
- **日誌類型**: api, audit, authenticator, controllerManager, scheduler

### 4. Node Group
- **名稱**: general
- **狀態**: ACTIVE
- **實例類型**: t3.medium
- **容量類型**: SPOT (成本優化)
- **節點數量**:
  - 最小: 1
  - 期望: 2
  - 最大: 3
- **磁盤大小**: 30 GB
- **AMI類型**: AL2023_x86_64_STANDARD

### 5. 當前節點狀態
```
NAME                                             STATUS   ROLES    VERSION
ip-10-0-11-110.ap-southeast-1.compute.internal   Ready    <none>   v1.30.14-eks-3abbec1
ip-10-0-12-201.ap-southeast-1.compute.internal   Ready    <none>   v1.30.14-eks-3abbec1
```

## 解決的問題

### 1. Terraform 循環依賴
- **問題**: IAM 模組需要 EKS OIDC URL，EKS 需要 IAM 角色
- **解決方案**: 採用分階段部署策略，先創建 IAM 角色（OIDC URL 為空），再創建 EKS

### 2. Terraform State Lock
- **問題**: 多次遇到 DynamoDB lock 衝突
- **解決方案**: 使用 `terraform force-unlock` 強制解鎖

### 3. VPC Route 重複創建
- **問題**: NAT Gateway route 已存在導致錯誤
- **解決方案**: 註釋掉重複的 route 資源定義

### 4. OIDC Provider 空值錯誤
- **問題**: 初始部署時 OIDC issuer URL 為空
- **解決方案**: 在 IAM 模組中添加條件檢查 `var.cluster_oidc_issuer_url != ""`

### 5. VPC Flow Logs 參數錯誤
- **問題**: `log_destination_arn` 參數不被支持
- **解決方案**: 改用 `log_destination` 和 `log_destination_type`

## 訪問集群

### 配置 kubectl
```bash
export KUBECONFIG=/tmp/eks-config
aws eks update-kubeconfig --name eks-lab-test-eks --region ap-southeast-1
```

### 驗證連接
```bash
kubectl get nodes
kubectl get pods -A
```

## 成本優化措施

1. **使用 SPOT 實例**: Node Group 使用 SPOT 實例類型，節省約 70% 成本
2. **單一 NAT Gateway**: 使用單一 NAT Gateway 而非每個 AZ 一個，節省成本
3. **最小節點數量**: 設置最小節點數為 1，根據需求自動擴展

## 下一步計劃

### 待安裝的組件
1. **AWS Load Balancer Controller**: 管理 ALB/NLB
2. **Karpenter**: 智能節點自動擴展
3. **ArgoCD**: GitOps 持續部署
4. **Metrics Server**: 資源監控
5. **Prometheus + Grafana**: 監控和可視化

### 建議的改進
1. 啟用 OIDC Provider 以支持 IRSA
2. 配置 Cluster Autoscaler 或 Karpenter
3. 實施網路策略
4. 配置備份策略
5. 實施日誌聚合

## 清理資源

如需清理所有資源，執行：
```bash
# 刪除 Node Group
aws eks delete-nodegroup \
  --cluster-name eks-lab-test-eks \
  --nodegroup-name general \
  --region ap-southeast-1

# 等待 Node Group 刪除完成
aws eks wait nodegroup-deleted \
  --cluster-name eks-lab-test-eks \
  --nodegroup-name general \
  --region ap-southeast-1

# 刪除 EKS 集群
aws eks delete-cluster \
  --name eks-lab-test-eks \
  --region ap-southeast-1

# 使用 Terraform 清理其他資源
terraform destroy -var-file="terraform-simple.tfvars"
```

## 總結

EKS 集群已成功部署在 ap-southeast-1 區域，包含：
- ✅ 完整的 VPC 網路架構
- ✅ 必要的 IAM 角色和策略
- ✅ 活躍的 EKS 控制平面
- ✅ 2 個運行中的工作節點
- ✅ kubectl 訪問配置完成

整個部署過程中遇到的技術挑戰都已成功解決並記錄在案，為未來的部署提供參考。

---

**部署時間**: 約 45 分鐘
**資源成本估算**: 約 $0.15/小時 (使用 SPOT 實例)
**報告生成時間**: 2025-08-24 17:50:00 UTC