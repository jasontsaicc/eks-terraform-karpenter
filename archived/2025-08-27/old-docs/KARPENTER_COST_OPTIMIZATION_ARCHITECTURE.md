# Karpenter 成本優化架構設計

## 架構概述

### 核心設計理念
- **EKS Node Group**: 最小規格 (1-2 個 t3.small)，只運行系統關鍵 Pod
- **Karpenter Nodes**: 動態管理，運行所有應用 (GitLab, Runner, ArgoCD)
- **時間排程**: 下班時間自動縮減到零或最小節點

## 節點分配策略

### 1. 系統節點 (EKS Managed Node Group)
```yaml
規格: t3.small (2 vCPU, 2 GiB)
數量: 1-2 個節點
用途:
  - kube-system namespace 的核心組件
  - Karpenter Controller
  - AWS Load Balancer Controller
  - CoreDNS
  - Cert Manager
標籤: node-role=system
Taints: system-only=true:NoSchedule
```

### 2. 應用節點 (Karpenter 管理)
```yaml
規格: t3.medium 到 t3.xlarge (動態)
數量: 0-10 個節點 (根據負載)
用途:
  - GitLab
  - GitLab Runner
  - ArgoCD
  - 應用工作負載
標籤: node-role=application
成本: SPOT 優先，On-Demand 備用
```

## 時間排程策略

### 工作時間 (週一至週五 8:00-19:00)
- Karpenter 正常自動擴縮容
- 最小節點: 1-2 個應用節點
- 最大節點: 10 個節點

### 下班時間 (週一至週五 19:00-8:00)
- 縮減到 0-1 個應用節點
- 只保留必要的監控服務

### 週末 (週六、週日)
- 完全縮減到 0 個應用節點
- 除非有 CI/CD 任務觸發

## 成本預估

### 現有成本 (24/7 運行)
```
2 x t3.medium (On-Demand): $60/月
EKS Control Plane: $72/月
NAT Gateway: $45/月
總計: ~$177/月
```

### 優化後成本
```
1 x t3.small (系統節點): $15/月
Karpenter SPOT (工作時間 40%): $12/月
EKS Control Plane: $72/月
NAT Gateway: $45/月
總計: ~$144/月
節省: ~20%
```

## 實施步驟

1. 重新配置 EKS Node Group 為最小規格
2. 部署 Karpenter 與優化配置
3. 設定節點親和性規則
4. 實作時間排程 CronJob
5. 遷移應用到 Karpenter 節點
6. 測試自動擴縮容
7. 監控成本與性能

## 風險與緩解

### 風險 1: 冷啟動延遲
- **問題**: 下班後首次請求需要等待節點啟動
- **緩解**: 保留 1 個最小應用節點

### 風險 2: SPOT 實例中斷
- **問題**: SPOT 實例可能被回收
- **緩解**: 混合使用 SPOT 和 On-Demand

### 風險 3: 系統組件穩定性
- **問題**: 系統節點故障影響整個集群
- **緩解**: 配置 2 個系統節點高可用