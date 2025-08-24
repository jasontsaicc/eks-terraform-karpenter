# 通用變數
variable "project_name" {
  description = "專案名稱"
  type        = string
  default     = "eks-test"
}

variable "environment" {
  description = "環境名稱"
  type        = string
  default     = "test"
}

variable "region" {
  description = "AWS 區域"
  type        = string
  default     = "ap-southeast-1"
}

variable "azs" {
  description = "可用區域"
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
}

# VPC 配置
variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = "是否啟用 NAT Gateway"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "是否使用單一 NAT Gateway (成本優化)"
  type        = bool
  default     = true
}

# EKS 配置
variable "cluster_version" {
  description = "Kubernetes 版本"
  type        = string
  default     = "1.30"
}

variable "cluster_endpoint_private_access" {
  description = "啟用私有端點訪問"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "啟用公開端點訪問"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "允許訪問公開端點的 CIDR"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Node Group 配置
variable "node_group_desired_size" {
  description = "期望節點數量"
  type        = number
  default     = 2
}

variable "node_group_min_size" {
  description = "最小節點數量"
  type        = number
  default     = 1
}

variable "node_group_max_size" {
  description = "最大節點數量"
  type        = number
  default     = 5
}

variable "node_instance_types" {
  description = "節點實例類型"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "節點容量類型 (ON_DEMAND 或 SPOT)"
  type        = string
  default     = "SPOT"
}

variable "node_disk_size" {
  description = "節點磁碟大小 (GB)"
  type        = number
  default     = 30
}

# 標籤
variable "tags" {
  description = "資源標籤"
  type        = map(string)
  default = {
    ManagedBy   = "Terraform"
    Environment = "test"
    Purpose     = "EKS-Testing"
  }
}

# 成本優化選項
variable "enable_spot_instances" {
  description = "啟用 Spot 實例"
  type        = bool
  default     = true
}

variable "spot_max_price" {
  description = "Spot 實例最高價格"
  type        = string
  default     = ""
}

# 安全選項
variable "enable_irsa" {
  description = "啟用 IRSA (IAM Roles for Service Accounts)"
  type        = bool
  default     = true
}

variable "enable_cluster_encryption" {
  description = "啟用集群加密"
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS 金鑰 ARN (留空則建立新的)"
  type        = string
  default     = ""
}

# EKS Add-ons
variable "enable_ebs_csi_driver" {
  description = "啟用 EBS CSI Driver"
  type        = bool
  default     = true
}