# Terraform Backend 基礎設施 - S3 bucket 和 DynamoDB 表
# 此配置用於建立 Terraform 遠端狀態儲存和鎖定機制

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

provider "aws" {
  region = var.region
  
  default_tags {
    tags = {
      ManagedBy = "Terraform"
      Purpose   = "Backend-Infrastructure"
      Project   = var.project_name
    }
  }
}

# 產生隨機後綴確保 S3 bucket 名稱唯一
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project_name}-terraform-state-${random_id.bucket_suffix.hex}"
  dynamodb_table_name = "${var.project_name}-terraform-state-lock"
}

# S3 Bucket 用於存放 Terraform 狀態檔案
resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy_bucket

  tags = {
    Name        = local.bucket_name
    Description = "Terraform 狀態儲存 bucket"
  }
}

# S3 Bucket 版本控制
resource "aws_s3_bucket_versioning" "terraform_state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket 伺服器端加密
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 Bucket 公共存取封鎖
resource "aws_s3_bucket_public_access_block" "terraform_state_pab" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Bucket 生命週期政策（可選）
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state_lifecycle" {
  count  = var.enable_lifecycle_policy ? 1 : 0
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "terraform_state_cleanup"
    status = "Enabled"

    # 添加 filter 來修正警告
    filter {}

    # 非當前版本在 30 天後刪除
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # 中止未完成的多部分上傳
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# DynamoDB 表用於 Terraform 狀態鎖定
resource "aws_dynamodb_table" "terraform_state_lock" {
  name           = local.dynamodb_table_name
  billing_mode   = "PAY_PER_REQUEST"  # 按需付費，適合測試環境
  hash_key       = "LockID"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = local.dynamodb_table_name
    Description = "Terraform 狀態鎖定表"
  }
}

# KMS 金鑰用於額外加密（可選）
resource "aws_kms_key" "terraform_state_key" {
  count = var.enable_kms_encryption ? 1 : 0
  
  description             = "KMS key for Terraform state encryption"
  deletion_window_in_days = var.kms_deletion_window
  
  tags = {
    Name = "${var.project_name}-terraform-state-key"
  }
}

resource "aws_kms_alias" "terraform_state_key_alias" {
  count = var.enable_kms_encryption ? 1 : 0
  
  name          = "alias/${var.project_name}-terraform-state"
  target_key_id = aws_kms_key.terraform_state_key[0].key_id
}

# 更新 S3 加密配置使用 KMS（如果啟用）
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_kms_encryption" {
  count  = var.enable_kms_encryption ? 1 : 0
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.terraform_state_key[0].arn
      sse_algorithm     = "aws:kms"
    }
  }
}