# GitOps 基礎設施配置
# 環境：生產環境
# 區域：ap-northeast-1 (東京)

# 基礎設施配置
cluster_name        = "gitops-eks-cluster"
region             = "ap-northeast-1"
environment        = "production"
owner              = "jasontsai"

# VPC 配置
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["ap-northeast-1a", "ap-northeast-1c"]

# 公有子網路 (NAT Gateway, ALB)
public_subnet_cidrs = [
  "10.0.1.0/24",   # AZ-1a
  "10.0.2.0/24"    # AZ-1c
]

# 私有子網路 (系統節點)
private_subnet_cidrs = [
  "10.0.10.0/24",  # AZ-1a 系統節點
  "10.0.11.0/24"   # AZ-1c 系統節點
]

# 應用子網路 (Karpenter 管理)
app_subnet_cidrs = [
  "10.0.20.0/24",  # AZ-1a 應用節點
  "10.0.21.0/24"   # AZ-1c 應用節點
]

# EKS 配置
kubernetes_version = "1.30"
enable_irsa       = true

# 系統節點組配置 (固定節點，運行核心服務)
system_node_groups = {
  system = {
    desired_capacity = 2
    min_capacity     = 2
    max_capacity     = 4
    instance_types   = ["t3.large"]
    
    labels = {
      role = "system"
      type = "on-demand"
    }
    
    taints = [
      {
        key    = "system"
        value  = "true"
        effect = "NoSchedule"
      }
    ]
    
    tags = {
      "karpenter.sh/discovery" = "gitops-eks-cluster"
      "node-type"              = "system"
    }
  }
}

# Karpenter 配置 (動態節點調配)
karpenter_config = {
  enabled = true
  version = "v0.35.0"
  
  # Spot 實例配置
  spot_enabled     = true
  spot_max_price   = "0.5"  # 最大 Spot 價格
  
  # 實例類型
  instance_families = ["t3", "t3a", "c5", "c5a", "m5", "m5a"]
  instance_sizes    = ["medium", "large", "xlarge"]
  
  # 擴展策略
  ttl_seconds_after_empty      = 30
  ttl_seconds_until_expired    = 2592000  # 30 天
  
  # 成本優化
  consolidation_enabled = true
  
  # 限制
  limits = {
    cpu    = 1000
    memory = "1000Gi"
  }
}

# GitLab 配置
gitlab_config = {
  enabled = true
  
  # 版本
  version = "16.11.0"
  
  # 資源配置
  replicas = 2
  
  # 存儲
  storage_class = "gp3"
  storage_size  = "100Gi"
  
  # 資料庫 (RDS)
  database = {
    enabled        = true
    instance_class = "db.t3.medium"
    engine_version = "15.4"
    storage        = 20
    multi_az       = true
  }
  
  # Redis (ElastiCache)
  redis = {
    enabled        = true
    node_type      = "cache.t3.micro"
    num_cache_nodes = 2
  }
  
  # 物件存儲 (S3)
  object_storage = {
    artifacts   = true
    lfs         = true
    packages    = true
    registry    = true
    backups     = true
  }
}

# ArgoCD 配置
argocd_config = {
  enabled = true
  version = "6.7.3"
  
  # 高可用配置
  ha_enabled = true
  replicas = {
    server     = 2
    repo_server = 2
    controller = 2
  }
  
  # 存儲
  redis_ha = true
  
  # 同步策略
  sync_policy = {
    automated = {
      prune    = true
      selfHeal = true
    }
    retry = {
      limit = 5
      backoff = {
        duration    = "5s"
        factor      = 2
        maxDuration = "3m"
      }
    }
  }
}

# AWS Load Balancer Controller
alb_controller_config = {
  enabled = true
  version = "2.7.1"
  
  # 預設 IngressClass
  default_ingress_class = "alb"
  
  # WAF 整合
  waf_enabled = true
  waf_rules   = ["AWSManagedRulesCommonRuleSet"]
}

# 監控配置
monitoring_config = {
  prometheus = {
    enabled = true
    retention = "30d"
    storage_size = "50Gi"
  }
  
  grafana = {
    enabled = true
    admin_password = "changeme"  # 請使用 AWS Secrets Manager
  }
  
  loki = {
    enabled = true
    retention = "7d"
    storage_size = "20Gi"
  }
}

# 安全配置
security_config = {
  # Network Policies
  network_policies_enabled = true
  
  # Pod Security Standards
  pod_security_standards = "restricted"
  
  # 加密
  encryption_at_rest = true
  kms_key_rotation   = true
  
  # 審計日誌
  audit_logging = true
  
  # OIDC 提供者
  enable_oidc_provider = true
}

# 備份配置
backup_config = {
  enabled = true
  
  # Velero 配置
  velero = {
    enabled = true
    s3_bucket = "gitops-eks-cluster-backups"
    schedule = "0 2 * * *"  # 每天凌晨 2 點
    retention = "30d"
  }
  
  # GitLab 備份
  gitlab_backup = {
    enabled = true
    schedule = "0 3 * * *"  # 每天凌晨 3 點
    retention = "7d"
  }
}

# 標籤
tags = {
  Environment = "production"
  ManagedBy   = "terraform"
  Owner       = "jasontsai"
  Project     = "gitops-infrastructure"
  CostCenter  = "engineering"
}