# Outputs for Terraform Backend Infrastructure

output "s3_bucket_name" {
  description = "Terraform 狀態儲存的 S3 bucket 名稱"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "s3_bucket_region" {
  description = "S3 bucket 所在區域"
  value       = aws_s3_bucket.terraform_state.region
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.terraform_state.arn
}

output "dynamodb_table_name" {
  description = "Terraform 狀態鎖定的 DynamoDB 表名稱"
  value       = aws_dynamodb_table.terraform_state_lock.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB 表 ARN"
  value       = aws_dynamodb_table.terraform_state_lock.arn
}

output "kms_key_id" {
  description = "KMS 金鑰 ID（如果啟用）"
  value       = var.enable_kms_encryption ? aws_kms_key.terraform_state_key[0].id : null
}

output "kms_key_arn" {
  description = "KMS 金鑰 ARN（如果啟用）"
  value       = var.enable_kms_encryption ? aws_kms_key.terraform_state_key[0].arn : null
}

# 輸出後端配置資訊，方便複製到主要 Terraform 配置
output "backend_configuration" {
  description = "Terraform backend 配置資訊"
  value = {
    bucket         = aws_s3_bucket.terraform_state.bucket
    key            = "eks/terraform.tfstate"
    region         = var.region
    dynamodb_table = aws_dynamodb_table.terraform_state_lock.name
    encrypt        = true
  }
}

# 輸出 terraform backend 配置格式，可直接複製使用
output "terraform_backend_config" {
  description = "Terraform backend 配置（HCL 格式）"
  value = <<-EOT
terraform {
  backend "s3" {
    bucket         = "${aws_s3_bucket.terraform_state.bucket}"
    key            = "eks/terraform.tfstate"
    region         = "${var.region}"
    dynamodb_table = "${aws_dynamodb_table.terraform_state_lock.name}"
    encrypt        = true
  }
}
EOT
}