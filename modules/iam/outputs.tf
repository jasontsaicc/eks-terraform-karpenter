output "cluster_iam_role_arn" {
  description = "EKS Cluster IAM Role ARN"
  value       = aws_iam_role.eks_cluster.arn
}

output "cluster_iam_role_name" {
  description = "EKS Cluster IAM Role Name"
  value       = aws_iam_role.eks_cluster.name
}

output "node_group_iam_role_arn" {
  description = "EKS Node Group IAM Role ARN"
  value       = aws_iam_role.eks_node_group.arn
}

output "node_group_iam_role_name" {
  description = "EKS Node Group IAM Role Name"
  value       = aws_iam_role.eks_node_group.name
}

output "oidc_provider_arn" {
  description = "OIDC Provider ARN"
  value       = var.enable_irsa ? aws_iam_openid_connect_provider.eks[0].arn : ""
}

output "karpenter_controller_role_arn" {
  description = "Karpenter Controller IAM Role ARN"
  value       = var.enable_karpenter ? aws_iam_role.karpenter_controller[0].arn : ""
}

output "karpenter_instance_profile_name" {
  description = "Karpenter Instance Profile Name"
  value       = var.enable_karpenter ? aws_iam_instance_profile.karpenter[0].name : ""
}

output "aws_load_balancer_controller_role_arn" {
  description = "AWS Load Balancer Controller IAM Role ARN"
  value       = var.enable_aws_load_balancer_controller ? aws_iam_role.aws_load_balancer_controller[0].arn : ""
}

output "ebs_csi_driver_role_arn" {
  description = "EBS CSI Driver IAM Role ARN"
  value       = var.enable_ebs_csi_driver ? aws_iam_role.ebs_csi_driver[0].arn : ""
}