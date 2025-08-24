variable "project_name" {
  description = "專案名稱"
  type        = string
}

variable "environment" {
  description = "環境名稱"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "azs" {
  description = "可用區域列表"
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "是否啟用 NAT Gateway"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "是否使用單一 NAT Gateway"
  type        = bool
  default     = false
}

variable "create_database_subnets" {
  description = "是否建立資料庫子網路"
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "是否啟用 VPC Flow Logs"
  type        = bool
  default     = false
}

variable "cluster_name" {
  description = "EKS cluster 名稱"
  type        = string
}

variable "tags" {
  description = "資源標籤"
  type        = map(string)
  default     = {}
}