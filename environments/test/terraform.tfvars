# 測試環境配置

# 基本設定
project_name = "eks-lab"
environment  = "test"
region       = "ap-southeast-1"
azs          = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

# VPC 配置
vpc_cidr           = "10.0.0.0/16"
enable_nat_gateway = true
single_nat_gateway = true  # 成本優化：使用單一 NAT Gateway

# EKS 配置
cluster_version                      = "1.30"
cluster_endpoint_private_access      = true
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # 生產環境應限制 IP

# Node Group 配置（成本優化）
node_group_desired_size = 2
node_group_min_size     = 1
node_group_max_size     = 4
node_instance_types     = ["t3.medium"]  # 測試環境使用較小實例
node_capacity_type      = "SPOT"         # 使用 Spot 實例節省成本
node_disk_size          = 30

# 成本優化選項
enable_spot_instances = true
spot_max_price       = ""  # 留空使用 on-demand 價格作為上限

# 安全選項
enable_irsa                = true
enable_cluster_encryption  = true
kms_key_arn               = ""  # 留空將自動建立新的 KMS key

# 標籤
tags = {
  ManagedBy   = "Terraform"
  Environment = "test"
  Purpose     = "EKS-Testing"
  CostCenter  = "DevOps"
  Owner       = "Platform-Team"
}