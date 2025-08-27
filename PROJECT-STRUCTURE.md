# AWS EKS Terraform 項目結構

## 📁 當前活躍文件結構

```
aws_eks_terraform/
├── 📋 主要配置文件
│   ├── main.tf                    # 主要 Terraform 配置
│   ├── variables.tf               # Terraform 變數定義
│   ├── README.md                  # 項目總覽說明
│   └── quick-deploy.sh           # 快速部署腳本
│
├── 📁 configs/                   # 配置文件目錄
│   ├── current/                  # 當前使用的配置
│   │   ├── terraform.tfvars      # 主要環境配置
│   │   ├── terraform.tfvars.simple # 簡化配置範本
│   │   ├── backend-config.hcl     # Terraform 後端配置
│   │   └── karpenter-resources.yaml # Karpenter 資源定義
│   └── helm-values/              # Helm Chart 配置
│       └── gitlab-runner-values.yaml # GitLab Runner 配置
│
├── 📁 docs/                      # 文檔目錄
│   ├── current/                  # 當前活躍文檔
│   │   ├── EKS-DEPLOYMENT-GUIDE.md    # 完整部署指南 (490行)
│   │   └── SYSTEM-STATUS-REPORT.md    # 系統狀態報告
│   └── TROUBLESHOOTING_GUIDE.md # 故障排除指南
│
├── 📁 modules/                   # Terraform 模組
│   ├── eks/                      # EKS 集群模組
│   ├── vpc/                      # VPC 網路模組
│   └── iam/                      # IAM 角色模組
│
├── 📁 scripts/                   # 運維腳本
│   ├── force-cleanup.sh          # 強制清理腳本 ⭐
│   ├── install-karpenter.sh      # Karpenter 安裝腳本 ⭐
│   ├── validate-deployment.sh    # 部署驗證腳本
│   ├── setup-backend.sh          # 後端設置腳本
│   ├── setup-addons.sh           # 附加組件設置
│   ├── monitor-costs.sh          # 成本監控腳本
│   └── quick-health-check.sh     # 快速健康檢查
│
├── 📁 tests/                     # 測試文件
│   └── current/
│       └── test-app.yaml         # 測試應用配置
│
├── 📁 environments/              # 多環境配置
│   └── test/
│       └── terraform.tfvars     # 測試環境配置
│
├── 📁 gitops-apps/              # GitOps 應用定義
│   ├── dev/                     # 開發環境應用
│   ├── staging/                 # 測試環境應用
│   └── prod/                    # 生產環境應用
│
└── 📁 archived/                 # 歷史歸檔
    ├── 2025-08-27/             # 今日歸檔
    │   ├── old-docs/           # 舊文檔
    │   ├── old-configs/        # 舊配置
    │   ├── old-tests/          # 舊測試
    │   └── old-scripts/        # 舊腳本
    └── [其他歷史歸檔]
```

## 🚀 關鍵文件說明

### ⭐ 核心部署文件
| 文件 | 用途 | 重要性 |
|------|------|--------|
| `main.tf` | 主要基礎設施定義 | 🔴 必需 |
| `configs/current/terraform.tfvars` | 環境配置 | 🔴 必需 |
| `quick-deploy.sh` | 自動化部署 | 🟡 推薦 |

### 📚 文檔文件
| 文件 | 內容 | 狀態 |
|------|------|------|
| `docs/current/EKS-DEPLOYMENT-GUIDE.md` | 完整部署指南 (490行) | ✅ 最新 |
| `docs/current/SYSTEM-STATUS-REPORT.md` | 系統狀態報告 | ✅ 最新 |
| `README.md` | 項目總覽 | ✅ 活躍 |

### 🔧 運維腳本
| 腳本 | 功能 | 使用場景 |
|------|------|----------|
| `scripts/force-cleanup.sh` | 強制清理所有 AWS 資源 | 🆘 緊急清理 |
| `scripts/install-karpenter.sh` | Karpenter 自動安裝 | 🚀 新部署 |
| `scripts/validate-deployment.sh` | 驗證部署狀態 | ✅ 部署後檢查 |

### ⚙️ 配置文件
| 文件 | 用途 | 建議 |
|------|------|------|
| `configs/current/terraform.tfvars.simple` | 簡化配置範本 | 🟢 新手使用 |
| `configs/helm-values/gitlab-runner-values.yaml` | CI/CD 配置 | 🟡 可選 |

## 🗂️ 歸檔文件說明

### 已歸檔的過時文件
- **舊文檔**: 重複或過時的部署指南
- **舊配置**: 不再使用的 Terraform 配置
- **舊腳本**: 被新腳本替代的部署腳本
- **舊測試**: 歷史測試文件

## 🎯 使用建議

### 新用戶快速開始
1. 閱讀 `docs/current/EKS-DEPLOYMENT-GUIDE.md`
2. 使用 `configs/current/terraform.tfvars.simple`
3. 運行 `quick-deploy.sh`

### 經驗用戶
1. 直接編輯 `configs/current/terraform.tfvars`
2. 使用 `scripts/` 中的專用腳本
3. 參考 `docs/current/SYSTEM-STATUS-REPORT.md` 了解當前狀態

### 故障排除
1. 查看 `docs/TROUBLESHOOTING_GUIDE.md`
2. 使用 `scripts/force-cleanup.sh` 進行清理
3. 檢查 `archived/` 中的歷史問題報告

## 📋 維護說明

### 文件生命週期
- **活躍文件**: 保持在主目錄和對應的功能目錄中
- **過時文件**: 移動到 `archived/YYYY-MM-DD/` 對應分類目錄
- **測試文件**: 保留在 `tests/current/` 中

### 版本控制
- 重要配置變更前備份到 `archived/backup/`
- 使用日期命名歸檔目錄
- 保留重要的歷史版本用於回滾

---

*結構整理日期: 2025-08-27*  
*下次整理建議: 2025-09-27 或重大變更時*