# 簡化的 EKS 配置檔案
# 用於快速部署和測試

# 基礎設定
project_name = "eks-lab"
environment  = "test"
region       = "ap-southeast-1"

# 可用區域
azs = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

# VPC 配置
vpc_cidr           = "10.0.0.0/16"
enable_nat_gateway = true
single_nat_gateway = true  # 成本優化：只使用一個 NAT Gateway

# EKS 集群配置
cluster_version                      = "1.30"
cluster_endpoint_private_access      = true
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

# 節點組配置
node_group_desired_size = 2
node_group_min_size     = 1
node_group_max_size     = 4
node_instance_types     = ["t3.small"]  # 成本優化
node_capacity_type      = "ON_DEMAND"   # 先用 On-Demand 確保穩定性
node_disk_size         = 20

# 功能啟用
enable_irsa                         = true
enable_ebs_csi_driver              = true
enable_karpenter                    = true
enable_aws_load_balancer_controller = true

# 標籤
tags = {
  Project     = "eks-lab"
  Environment = "test"
  ManagedBy   = "terraform"
  CostCenter  = "optimization"
  Owner       = "devops-team"
}