# Optimized EKS Configuration for Karpenter Cost Optimization
# System nodes: Minimal t3.small for core components
# Application nodes: Managed by Karpenter

project_name = "eks-lab"
environment  = "test"
region       = "ap-southeast-1"

# VPC Configuration
vpc_cidr = "10.0.0.0/16"
azs      = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS Configuration
cluster_version = "1.30"

# Minimal Node Group for System Components Only
node_groups = {
  system = {
    desired_size = 2      # 2 nodes for HA
    min_size     = 1      # Can scale down to 1
    max_size     = 3      # Can scale up if needed
    
    # Small instance for system components only
    instance_types = ["t3.small"]  # 2 vCPU, 2 GiB RAM
    capacity_type  = "ON_DEMAND"   # System nodes should be stable
    
    # Disk configuration
    disk_size = 20  # Minimal disk for system components
    
    # Labels for node selection
    labels = {
      role = "system"
      node-type = "system"
    }
    
    # Taints to prevent application pods
    taints = [
      {
        key    = "system-only"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    ]
    
    # Tags
    tags = {
      Environment = "test"
      Type        = "system"
      ManagedBy   = "terraform"
    }
  }
}

# Karpenter Configuration
enable_karpenter = true
karpenter_version = "v0.35.0"

# Cost optimization settings
enable_spot_instances = true
spot_max_price = "0.05"  # Maximum price for SPOT instances

# GitOps Tools (will run on Karpenter nodes)
enable_argocd = true
enable_gitlab = true

# Tags
tags = {
  Environment = "test"
  Project     = "eks-lab"
  ManagedBy   = "terraform"
  CostCenter  = "optimization"
}