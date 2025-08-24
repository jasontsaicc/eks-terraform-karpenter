variable "project_name" {
  description = "專案名稱"
  type        = string
}

variable "environment" {
  description = "環境名稱"
  type        = string
}

variable "region" {
  description = "AWS 區域"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "公開子網路 IDs"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "私有子網路 IDs"
  type        = list(string)
}

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

variable "enable_cluster_encryption" {
  description = "啟用集群加密"
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "KMS 金鑰 ARN"
  type        = string
  default     = ""
}

variable "cluster_log_types" {
  description = "啟用的集群日誌類型"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "集群日誌保留天數"
  type        = number
  default     = 7
}

variable "cluster_iam_role_arn" {
  description = "EKS Cluster IAM Role ARN"
  type        = string
}

variable "node_group_iam_role_arn" {
  description = "Node Group IAM Role ARN"
  type        = string
}

variable "node_groups" {
  description = "Node groups 配置"
  type = map(object({
    desired_size   = number
    min_size       = number
    max_size       = number
    instance_types = list(string)
    capacity_type  = string
    labels         = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
    tags = map(string)
  }))
  default = {
    general = {
      desired_size   = 2
      min_size       = 1
      max_size       = 5
      instance_types = ["t3.medium"]
      capacity_type  = "SPOT"
      labels         = {}
      taints         = []
      tags           = {}
    }
  }
}

variable "node_disk_size" {
  description = "節點磁碟大小 (GB)"
  type        = number
  default     = 30
}

variable "node_group_additional_userdata" {
  description = "額外的 user data script"
  type        = string
  default     = ""
}

variable "enable_irsa" {
  description = "啟用 IRSA"
  type        = bool
  default     = true
}

variable "enable_ebs_csi_driver" {
  description = "啟用 EBS CSI Driver"
  type        = bool
  default     = true
}

variable "vpc_cni_version" {
  description = "VPC CNI addon 版本"
  type        = string
  default     = null
}

variable "kube_proxy_version" {
  description = "Kube Proxy addon 版本"
  type        = string
  default     = null
}

variable "coredns_version" {
  description = "CoreDNS addon 版本"
  type        = string
  default     = null
}

variable "ebs_csi_driver_version" {
  description = "EBS CSI Driver addon 版本"
  type        = string
  default     = null
}

variable "vpc_cni_role_arn" {
  description = "VPC CNI IAM Role ARN"
  type        = string
  default     = ""
}

variable "ebs_csi_driver_role_arn" {
  description = "EBS CSI Driver IAM Role ARN"
  type        = string
  default     = ""
}

variable "tags" {
  description = "資源標籤"
  type        = map(string)
  default     = {}
}