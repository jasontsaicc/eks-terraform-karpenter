# Variables for Terraform Backend Infrastructure

variable "project_name" {
  description = "專案名稱，用於命名資源"
  type        = string
  default     = "eks-lab"
}

variable "region" {
  description = "AWS 區域"
  type        = string
  default     = "ap-southeast-1"
}

variable "force_destroy_bucket" {
  description = "是否強制刪除非空的 S3 bucket（測試環境可設為 true）"
  type        = bool
  default     = true  # 測試環境設為 true，生產環境應設為 false
}

variable "enable_lifecycle_policy" {
  description = "是否啟用 S3 生命週期政策"
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "是否啟用 DynamoDB 刪除保護"
  type        = bool
  default     = false  # 測試環境設為 false，生產環境應設為 true
}

variable "enable_kms_encryption" {
  description = "是否使用 KMS 金鑰加密 S3 bucket"
  type        = bool
  default     = false  # 簡單測試可設為 false，生產環境建議 true
}

variable "kms_deletion_window" {
  description = "KMS 金鑰刪除等待期（天）"
  type        = number
  default     = 7  # 測試環境設為 7 天，生產環境建議 30 天
}

# 標籤
variable "tags" {
  description = "資源標籤"
  type        = map(string)
  default = {
    Environment = "test"
    ManagedBy   = "Terraform"
    Purpose     = "Backend-Infrastructure"
  }
}
