variable "cluster_name" {
  description = "EKS cluster 名稱"
  type        = string
}

variable "tags" {
  description = "資源標籤"
  type        = map(string)
  default     = {}
}

variable "enable_irsa" {
  description = "啟用 IRSA"
  type        = bool
  default     = true
}

variable "cluster_oidc_issuer_url" {
  description = "EKS cluster OIDC issuer URL"
  type        = string
  default     = ""
}

variable "enable_karpenter" {
  description = "啟用 Karpenter"
  type        = bool
  default     = false
}

variable "enable_aws_load_balancer_controller" {
  description = "啟用 AWS Load Balancer Controller"
  type        = bool
  default     = true
}

variable "enable_ebs_csi_driver" {
  description = "啟用 EBS CSI Driver"
  type        = bool
  default     = true
}