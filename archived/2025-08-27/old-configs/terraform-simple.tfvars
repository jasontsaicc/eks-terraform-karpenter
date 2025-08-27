# Simple test configuration for ap-southeast-1

# Basic settings
project_name = "eks-lab"
environment  = "test"
region       = "ap-southeast-1"
azs          = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

# VPC configuration
vpc_cidr           = "10.0.0.0/16"
enable_nat_gateway = true
single_nat_gateway = true  # Cost optimization for test

# EKS configuration
cluster_version                      = "1.30"
cluster_endpoint_private_access      = true
cluster_endpoint_public_access       = true
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]

# Node Group configuration (cost optimized)
node_group_desired_size = 2
node_group_min_size     = 1
node_group_max_size     = 3
node_instance_types     = ["t3.medium"]
node_capacity_type      = "SPOT"  # Use Spot for cost savings
node_disk_size          = 30

# Cost optimization
enable_spot_instances = true
spot_max_price       = ""

# Security options
enable_irsa                = true
enable_cluster_encryption  = false  # Disable to avoid KMS complexity
kms_key_arn               = ""
enable_ebs_csi_driver     = true

# Tags
tags = {
  ManagedBy   = "Terraform"
  Environment = "test"
  Purpose     = "EKS-Testing"
  Owner       = "jasontsai"
}