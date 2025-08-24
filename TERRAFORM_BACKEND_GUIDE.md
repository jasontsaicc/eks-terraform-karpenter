# 🏗️ Terraform Backend 完整設定指南

## 📋 概述

這份指南將教您如何設定 Terraform 遠端狀態儲存，這是生產環境的最佳實踐。我們將使用 AWS S3 儲存 Terraform 狀態檔案，並使用 DynamoDB 進行狀態鎖定，防止多人同時修改基礎設施時發生衝突。

### 🎯 為什麼需要 Terraform Backend？

**本地狀態的問題：**
- 狀態檔案只存在於單一機器
- 無法多人協作
- 容易遺失或損壞
- 缺乏版本控制和備份

**遠端 Backend 的優點：**
- ✅ 集中化狀態管理
- ✅ 支援團隊協作
- ✅ 自動鎖定防止衝突
- ✅ 版本控制和備份
- ✅ 加密儲存

## 🏗️ Backend 架構圖

```
┌─────────────────────────────────────────────────────────────┐
│                    Terraform Backend 架構                    │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │   開發者 A       │    │   開發者 B       │                │
│  │   terraform     │    │   terraform     │                │
│  │   apply         │    │   plan          │                │
│  └─────────────────┘    └─────────────────┘                │
│           │                       │                        │
│           └───────────┬───────────┘                        │
│                       │                                    │
│           ┌─────────────────────────────────┐              │
│           │        Terraform Backend        │              │
│           │                                 │              │
│  ┌─────────────────┐          ┌─────────────────────────┐  │
│  │   S3 Bucket     │          │    DynamoDB Table       │  │
│  │                 │          │                         │  │
│  │ ├─ tfstate      │          │ ├─ LockID (Hash Key)    │  │
│  │ ├─ versions     │          │ ├─ 鎖定資訊             │  │
│  │ ├─ encryption   │          │ ├─ 時間戳               │  │
│  │ └─ lifecycle    │          │ └─ 操作者資訊           │  │
│  └─────────────────┘          └─────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## 🚀 快速開始

### 步驟 1: 建立 Backend 基礎設施

```bash
# 1. 確認 AWS 認證設定
aws sts get-caller-identity

# 2. 執行 backend 設定腳本（完整流程）
./scripts/setup-backend.sh

# 或分步驟執行
./scripts/setup-backend.sh create    # 僅建立資源
./scripts/setup-backend.sh update    # 僅更新配置
./scripts/setup-backend.sh verify    # 僅驗證資源
```

### 步驟 2: 驗證 Backend 設定

```bash
# 初始化 Terraform 使用新的 backend
terraform init

# Terraform 會詢問是否要遷移狀態，選擇 "yes"
# Do you want to copy existing state to the new backend? yes
```

### 步驟 3: 測試 Backend 功能

```bash
# 檢查狀態是否已遷移到 S3
terraform state list

# 查看遠端狀態
terraform show
```

## 🔧 詳細設定說明

### Backend 資源組成

#### 1. S3 Bucket 配置
```hcl
# 主要功能
- 儲存 Terraform 狀態檔案
- 啟用版本控制
- 伺服器端加密 (AES256 或 KMS)
- 公共存取封鎖
- 生命週期政策管理

# 安全設定
- 封鎖所有公共存取
- 強制加密傳輸
- 版本控制保留歷史
- IAM 政策限制存取
```

#### 2. DynamoDB 表配置
```hcl
# 功能
- 提供分散式鎖定機制
- 防止同時修改衝突
- 按需付費模式節省成本

# 結構
Hash Key: LockID (String)
- 儲存鎖定狀態
- 記錄操作者資訊
- 時間戳追蹤
```

### 環境配置差異

#### 測試環境設定 (`terraform-backend/variables.tf`)
```hcl
# 測試環境 - 成本優化
force_destroy_bucket        = true   # 可強制刪除非空 bucket
enable_deletion_protection  = false  # 不啟用刪除保護
enable_kms_encryption      = false  # 使用 AES256 加密
kms_deletion_window        = 7      # KMS 金鑰 7 天刪除期
```

#### 生產環境建議
```hcl
# 生產環境 - 安全優先
force_destroy_bucket        = false  # 防止意外刪除
enable_deletion_protection  = true   # 啟用刪除保護
enable_kms_encryption      = true   # 使用 KMS 加密
kms_deletion_window        = 30     # KMS 金鑰 30 天刪除期
```

## 📖 腳本使用指南

### `setup-backend.sh` 命令參考

```bash
# 完整設定流程（推薦）
./scripts/setup-backend.sh

# 個別操作
./scripts/setup-backend.sh create    # 建立 backend 資源
./scripts/setup-backend.sh update    # 更新 main.tf 配置
./scripts/setup-backend.sh verify    # 驗證資源狀態
./scripts/setup-backend.sh cleanup   # 清理所有資源
./scripts/setup-backend.sh info      # 顯示 AWS 帳戶資訊
./scripts/setup-backend.sh help      # 顯示說明
```

### 腳本執行範例

```bash
$ ./scripts/setup-backend.sh create

[STEP] 檢查必要工具...
[INFO] 所有必要工具已就緒

[STEP] 顯示 AWS 帳戶資訊...
================================================
AWS 帳戶 ID: 123456789012
使用者/角色: arn:aws:iam::123456789012:user/terraform-user
預設區域: ap-east-2
================================================

[STEP] 建立 Terraform backend 基礎設施...
[INFO] 初始化 Terraform...
[INFO] 驗證 Terraform 配置...
[INFO] 規劃 backend 部署...

[WARN] 即將建立以下 AWS 資源：
  - S3 bucket (Terraform 狀態儲存)
  - DynamoDB 表 (狀態鎖定)
  - 相關的 IAM 政策和加密設定

確定要繼續嗎？ (yes/no): yes

[INFO] 開始部署 backend 基礎設施...

Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
```

## 🔍 狀態遷移詳解

### 從本地狀態遷移到遠端 Backend

```bash
# 1. 備份現有狀態（重要！）
cp terraform.tfstate terraform.tfstate.backup

# 2. 更新 main.tf 添加 backend 配置
terraform {
  backend "s3" {
    bucket         = "your-bucket-name"
    key            = "eks/terraform.tfstate"
    region         = "ap-east-2"
    dynamodb_table = "your-dynamodb-table"
    encrypt        = true
  }
}

# 3. 初始化並遷移
terraform init

# Terraform 提示訊息
Initializing the backend...
Do you want to copy existing state to the new backend?
  Pre-existing state was found while migrating the previous "local" backend to the
  newly configured "s3" backend. No existing state was found in the newly
  configured "s3" backend. Do you want to copy this state to the new "s3"
  backend? Enter "yes" to copy and "no" to start with an empty state.

  Enter a value: yes

# 4. 驗證遷移成功
terraform state list
```

### 驗證遠端狀態

```bash
# 檢查 S3 中的狀態檔案
aws s3 ls s3://your-bucket-name/eks/ --region ap-east-2

# 輸出範例：
2024-01-15 10:30:45      12345 terraform.tfstate

# 檢查 DynamoDB 鎖定表
aws dynamodb scan --table-name your-dynamodb-table --region ap-east-2
```

## 🛡️ 安全最佳實踐

### IAM 權限設定

為 Terraform 使用者建立專用的 IAM 政策：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::your-terraform-state-bucket",
        "arn:aws:s3:::your-terraform-state-bucket/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem"
      ],
      "Resource": "arn:aws:dynamodb:ap-east-2:account-id:table/your-lock-table"
    }
  ]
}
```

### 加密設定

```hcl
# S3 Bucket 加密
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"  # 或 "aws:kms"
    }
  }
}
```

## 🚨 故障排除

### 常見問題與解決方案

#### 1. Backend 初始化失敗
```bash
Error: Failed to get existing workspaces: S3 bucket does not exist.
```
**解決方案**：確認 S3 bucket 已建立且區域設定正確
```bash
aws s3api head-bucket --bucket your-bucket-name --region ap-east-2
```

#### 2. 狀態鎖定衝突
```bash
Error: Error locking state: Error acquiring the state lock
```
**解決方案**：檢查並清除過期的鎖定
```bash
# 查看鎖定狀態
aws dynamodb scan --table-name your-lock-table --region ap-east-2

# 如需要，手動清除鎖定（謹慎操作）
terraform force-unlock LOCK_ID
```

#### 3. 權限不足錯誤
```bash
Error: AccessDenied: Access Denied
```
**解決方案**：檢查 IAM 權限設定
```bash
aws sts get-caller-identity
aws iam get-user-policy --user-name your-user --policy-name terraform-policy
```

#### 4. 區域不匹配錯誤
```bash
Error: The bucket is in this region: ap-east-2. Please use this region.
```
**解決方案**：確保所有設定使用相同的區域

## 🔄 維護和監控

### 定期檢查

```bash
# 1. 檢查 S3 bucket 大小和版本數量
aws s3api list-object-versions --bucket your-bucket-name

# 2. 監控 DynamoDB 使用量
aws dynamodb describe-table --table-name your-lock-table

# 3. 檢查加密狀態
aws s3api get-bucket-encryption --bucket your-bucket-name
```

### 成本監控

```bash
# 使用 AWS CLI 查看成本
aws ce get-dimension-values --dimension SERVICE --time-period Start=2024-01-01,End=2024-01-31

# S3 儲存成本預估（每月）
# Standard storage: ~$0.025 per GB
# 狀態檔案通常 < 1MB，成本極低

# DynamoDB 成本預估
# 按需付費：讀取 $0.28/百萬次，寫入 $1.4/百萬次
# 正常使用下每月成本 < $1
```

## 📦 備份和恢復

### 狀態檔案備份

```bash
# 1. 自動版本控制（S3 自動功能）
aws s3api list-object-versions --bucket your-bucket-name --prefix eks/

# 2. 手動備份當前狀態
terraform state pull > backup-$(date +%Y%m%d).tfstate

# 3. 恢復到特定版本
terraform state push backup-20240115.tfstate
```

### 災難恢復程序

```bash
# 1. 重建 backend 基礎設施
./scripts/setup-backend.sh create

# 2. 恢復狀態檔案
aws s3 cp backup.tfstate s3://new-bucket-name/eks/terraform.tfstate

# 3. 更新配置並重新初始化
terraform init -reconfigure
```

## 🧹 清理指南

### 完整清理步驟

```bash
# 1. 備份重要狀態（如有需要）
terraform state pull > final-backup.tfstate

# 2. 銷毀主要基礎設施
terraform destroy -var-file=environments/test/terraform.tfvars

# 3. 清理 backend 資源
./scripts/setup-backend.sh cleanup

# 4. 驗證清理完成
aws s3 ls | grep terraform-state
aws dynamodb list-tables | grep terraform-state-lock
```

### 成本控制清理

```bash
# 僅保留 backend 資源，清理 EKS 集群
terraform destroy -target=module.eks -var-file=environments/test/terraform.tfvars

# 或使用腳本清理
./scripts/destroy.sh
```

## 📚 進階主題

### 多環境 Backend 設定

```bash
# 不同環境使用不同的狀態檔案路徑
# 開發環境
terraform init -backend-config="key=eks/dev/terraform.tfstate"

# 測試環境  
terraform init -backend-config="key=eks/test/terraform.tfstate"

# 生產環境
terraform init -backend-config="key=eks/prod/terraform.tfstate"
```

### Backend 配置檔案

建立 `backend.hcl` 檔案：
```hcl
bucket         = "your-terraform-state-bucket"
key            = "eks/terraform.tfstate"
region         = "ap-east-2" 
dynamodb_table = "your-terraform-state-lock"
encrypt        = true
```

使用配置檔案：
```bash
terraform init -backend-config=backend.hcl
```

---

## 🎉 總結

完成此指南後，您將擁有：

✅ **企業級的 Terraform 狀態管理**
✅ **安全的加密遠端儲存**  
✅ **防衝突的鎖定機制**
✅ **版本控制和備份**
✅ **成本優化的配置**
✅ **完整的災難恢復計劃**

**下一步**：執行主要的 EKS 部署
```bash
terraform init
terraform plan -var-file=environments/test/terraform.tfvars  
terraform apply -var-file=environments/test/terraform.tfvars
```

**記住**：Backend 資源是基礎設施的基礎，請謹慎管理和維護！