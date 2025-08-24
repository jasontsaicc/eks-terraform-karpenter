# 完整 EKS GitOps 部署指南

## 專案概述
這是一個完整的 AWS EKS Kubernetes 集群部署專案，包含 GitOps、自動擴展、負載均衡等企業級功能。

## 已部署的服務

| 服務名稱 | 狀態 | 版本 | 用途 |
|---------|------|------|------|
| **EKS Cluster** | ✅ 運行中 | 1.30 | Kubernetes 控制平面 |
| **VPC & Networking** | ✅ 運行中 | - | 網路基礎設施 |
| **IAM Roles & OIDC** | ✅ 配置完成 | - | 身份認證與授權 |
| **AWS Load Balancer Controller** | ✅ 運行中 | 2.8.2 | 管理 ALB/NLB |
| **Cert Manager** | ✅ 運行中 | 1.16.2 | SSL 證書管理 |
| **ArgoCD** | ✅ 運行中 | Latest | GitOps 持續部署 |
| **Metrics Server** | ✅ 運行中 | Latest | 資源監控 |
| **Karpenter** | ⚠️ 部分問題 | 0.16.3 | 節點自動擴展 |

## 清理資源腳本

請查看 scripts/cleanup-all.sh 進行資源清理

最後更新：2025-08-24
