# 🚨 EKS Terraform 部署錯誤排除手冊

## 📋 遇到的錯誤和解決方案

### ❌ 錯誤 1: Terraform Provider 重複配置

**錯誤訊息:**
```
Error: Duplicate required providers configuration
A module may have only one required providers configuration. The required providers were previously configured at main.tf:6,3-21.
```

**原因:** 
- `main.tf` 和 `versions.tf` 中都定義了 `required_providers`
- Terraform 不允許重複定義

**解決方案:**
```bash
# 刪除重複的 versions.tf 檔案
rm versions.tf
```

**預防措施:**
- 只在一個檔案中定義 `terraform` 區塊
- 建議在 `main.tf` 或專用的 `versions.tf` 中定義，但不要同時定義

---

### ❌ 錯誤 2: AWS Region 無效 (ap-east-2)

**錯誤訊息:**
```
Error: Invalid region value
Invalid AWS Region: ap-east-2
```

**原因:**
- Terraform 版本可能不支援較新的 AWS regions
- `ap-east-2` (台北) 是相對較新的 region

**解決方案 1:** 更新 AWS Provider 版本
```hcl
# 在 main.tf 中更新
required_providers {
  aws = {
    source  = "hashicorp/aws"
    version = "~> 5.0"  # 確保使用最新版本
  }
}
```

**解決方案 2:** 檢查 region 可用性
```bash
# 檢查可用 regions
aws ec2 describe-regions --region ap-east-1 --output table

# 暫時使用其他 region 測試
# 如 ap-east-1 (香港) 或 ap-southeast-1 (新加坡)
```

**解決方案 3:** 降級使用已確認的 region
```hcl
# 在 terraform.tfvars 中暫時修改
region = "ap-east-1"  # 改為香港 region 測試
azs    = ["ap-east-1a", "ap-east-1b", "ap-east-1c"]
```

---

### ⚠️ 警告 3: DynamoDB 參數已過時

**警告訊息:**
```
Warning: Deprecated Parameter
The parameter "dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.
```

**原因:**
- Terraform 較新版本中 `dynamodb_table` 參數已被棄用

**解決方案:**
```hcl
# 舊配置 (已棄用)
terraform {
  backend "s3" {
    bucket         = "bucket-name"
    key            = "terraform.tfstate"
    region         = "ap-east-1"
    dynamodb_table = "table-name"  # 已棄用
  }
}

# 新配置 (推薦)
terraform {
  backend "s3" {
    bucket               = "bucket-name"
    key                  = "terraform.tfstate"
    region               = "ap-east-1"
    dynamodb_table       = "table-name"  # 仍可使用但會有警告
    # 或使用新的參數
    use_lockfile         = true
  }
}
```

**注意:** 
- 警告不會阻止執行，但建議更新
- 舊參數在目前版本仍可正常使用

---

### ❌ 錯誤 4: S3 Lifecycle Configuration 警告

**警告訊息:**
```
Warning: Invalid Attribute Combination
No attribute specified when one (and only one) of [rule[0].filter,rule[0].prefix] is required
```

**原因:**
- AWS Provider 5.0+ 要求 S3 lifecycle rules 必須有 filter 或 prefix

**解決方案:**
```hcl
# 修正前
resource "aws_s3_bucket_lifecycle_configuration" "example" {
  bucket = aws_s3_bucket.example.id
  rule {
    id     = "cleanup"
    status = "Enabled"
    # 缺少 filter 或 prefix
  }
}

# 修正後
resource "aws_s3_bucket_lifecycle_configuration" "example" {
  bucket = aws_s3_bucket.example.id
  rule {
    id     = "cleanup" 
    status = "Enabled"
    filter {}  # 添加空的 filter
  }
}
```

---

## 🔧 通用故障排除步驟

### 1. 檢查 AWS 認證和權限
```bash
# 檢查認證
aws sts get-caller-identity

# 檢查 region 設定
aws configure get region

# 測試基本權限
aws s3 ls
aws ec2 describe-regions
```

### 2. 檢查 Terraform 版本相容性
```bash
# 檢查版本
terraform version
aws --version

# 更新 Terraform (如需要)
terraform version-upgrade

# 更新 providers
terraform init -upgrade
```

### 3. 清理和重新初始化
```bash
# 清理 .terraform 目錄
rm -rf .terraform
rm .terraform.lock.hcl

# 重新初始化
terraform init

# 驗證配置
terraform validate
```

### 4. Region 相關問題診斷
```bash
# 檢查 region 可用性
aws ec2 describe-regions --query 'Regions[].RegionName' --output table

# 檢查 region 中的可用區域
aws ec2 describe-availability-zones --region ap-east-1

# 檢查服務可用性
aws eks describe-cluster --name non-existent --region ap-east-1 2>/dev/null || echo "EKS 可用"
```

---

## 📝 錯誤修正實戰記錄

### 修正 Region 問題的步驟

1. **發現問題:**
   ```bash
   terraform init
   # Error: Invalid AWS Region: ap-east-2
   ```

2. **診斷步驟:**
   ```bash
   # 檢查 AWS CLI 支援的 regions
   aws ec2 describe-regions | grep ap-east
   
   # 檢查 Terraform AWS provider 版本
   terraform providers
   ```

3. **解決方案選擇:**
   - **選項 A:** 降級使用已確認的 region (推薦測試)
   - **選項 B:** 升級 Terraform 和 provider 版本
   - **選項 C:** 使用本地覆蓋檔案暫時修正

4. **實際修正:**
   ```bash
   # 選擇選項 A - 暫時使用 ap-east-1
   sed -i 's/ap-east-2/ap-east-1/g' terraform.tfvars
   sed -i 's/ap-east-2/ap-east-1/g' variables.tf
   sed -i 's/ap-east-2/ap-east-1/g' main.tf
   
   # 重新初始化
   terraform init
   ```

### 修正 Backend 配置的步驟

1. **更新 main.tf 中的 region:**
   ```hcl
   terraform {
     backend "s3" {
       bucket         = "eks-lab-terraform-state-60b77ac3"
       key            = "eks/terraform.tfstate"
       region         = "ap-east-1"  # 修正為有效 region
       dynamodb_table = "eks-lab-terraform-state-lock"
       encrypt        = true
     }
   }
   ```

2. **重新建立 backend (如需要):**
   ```bash
   # 如果 backend region 不匹配，需要重建
   cd terraform-backend
   terraform destroy -auto-approve
   
   # 修正 region 配置
   terraform apply -auto-approve
   
   # 更新主配置
   cd ..
   terraform init
   ```

---

## 🎯 最佳實踐建議

### 1. Region 選擇策略
- **測試環境:** 使用已確認支援的 region (如 ap-east-1, ap-southeast-1)
- **生產環境:** 確認目標 region 支援所有需要的服務
- **成本考量:** 不同 region 有不同價格，選擇合適的 region

### 2. 版本管理
```hcl
# 使用特定版本而非範圍，避免意外更新
terraform {
  required_version = "= 1.5.7"  # 固定版本
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.31.0"  # 固定版本
    }
  }
}
```

### 3. 錯誤預防
- 使用 `terraform validate` 在部署前驗證
- 設定 pre-commit hooks 檢查配置
- 使用 CI/CD pipeline 自動檢查

### 4. Backend 管理
- Backend 資源使用與主要基礎設施不同的 region 或帳戶
- 定期備份 terraform state
- 使用版本控制管理 backend 配置

---

## 📞 遇到新錯誤時的處理流程

1. **記錄完整錯誤訊息**
2. **檢查 Terraform 和 provider 版本**
3. **查閱官方文檔確認參數變更**
4. **在測試環境嘗試解決方案**
5. **記錄成功的解決步驟**
6. **更新此手冊**

---

### ❌ 錯誤 5: AWS 認證在特定 Region 失效

**錯誤訊息:**
```
Error: Retrieving AWS account details: validating provider credentials: retrieving caller identity from STS: operation error STS: GetCallerIdentity, https response error StatusCode: 403, RequestID: xxx, api error InvalidClientTokenId: The security token included in the request is invalid.
```

**原因:**
- 某些 AWS regions 可能需要特殊的啟用或權限
- 帳戶可能在某些 region 沒有權限
- STS endpoint 在特定 region 不可用

**診斷步驟:**
```bash
# 1. 檢查認證在預設 region 是否有效
aws sts get-caller-identity

# 2. 檢查預設 region
aws configure get region

# 3. 測試特定 region 的權限
aws sts get-caller-identity --region ap-east-1
aws sts get-caller-identity --region ap-east-2

# 4. 檢查帳戶啟用的 regions
aws account get-region-opt-status --region-name ap-east-2
```

**解決方案:**
1. **使用原始 region** (推薦)
   ```bash
   # 改回原始 region (ap-east-2)
   export AWS_DEFAULT_REGION=ap-east-2
   ```

2. **檢查 region 啟用狀態**
   ```bash
   # 某些新 regions 需要手動啟用
   aws account enable-region --region-name ap-east-2
   ```

3. **使用已確認的 region**
   ```bash
   # 改為確認可用的 region
   region = "ap-southeast-1"  # 新加坡
   ```

**注意:** 
- `ap-east-2` (台北) 確實存在，但可能需要帳戶特殊啟用
- 建議先用已確認的 region 完成測試

---

### ❌ 錯誤 6: Terraform 舊版本不認識新 Region

**錯誤訊息:**
```
Error: Invalid region value
Invalid AWS Region: ap-east-2
```

**原因:**
- Terraform AWS Provider 版本太舊
- 新 regions 在舊版本中不被支援

**解決方案:**
```bash
# 1. 更新 AWS Provider
terraform init -upgrade

# 2. 或在 terraform 配置中指定最新版本
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"  # 使用最新 5.x 版本
    }
  }
}

# 3. 清理並重新初始化
rm -rf .terraform .terraform.lock.hcl
terraform init
```

這份手冊會持續更新，記錄更多遇到的問題和解決方案！