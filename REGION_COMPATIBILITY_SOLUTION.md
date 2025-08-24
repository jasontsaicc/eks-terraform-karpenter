# 🌏 AWS Region 相容性解決方案

## 問題描述

Terraform v1.13.0 不支援較新的 AWS regions，包括 `ap-east-2` (台北)。

## 解決方案

### 方案 1: 升級 Terraform (建議生產環境)

```bash
# 下載最新版 Terraform
wget https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_linux_arm64.zip
unzip terraform_1.5.7_linux_arm64.zip
sudo mv terraform /usr/local/bin/

# 驗證版本
terraform version
```

### 方案 2: 使用相容的 Region (快速測試)

```bash
# 使用已支援的 region 進行測試
# ap-southeast-1 (新加坡) - 距離台灣較近，延遲較低
export AWS_DEFAULT_REGION=ap-southeast-1

# 更新所有配置檔案
sed -i 's/ap-east-2/ap-southeast-1/g' main.tf
sed -i 's/ap-east-2/ap-southeast-1/g' variables.tf  
sed -i 's/ap-east-2/ap-southeast-1/g' environments/test/terraform.tfvars
sed -i 's/ap-east-2/ap-southeast-1/g' terraform-backend/variables.tf
```

### 方案 3: 手動指定 Provider 版本

```hcl
# 在 main.tf 中使用最新版本
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.31"  # 支援最新 regions
    }
  }
}
```

## 實際執行

為了完成這次測試，我們使用方案 2：