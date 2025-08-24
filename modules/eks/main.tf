# EKS Cluster 配置

locals {
  cluster_name = "${var.project_name}-${var.environment}-eks"
}

# KMS Key for EKS Cluster Encryption
resource "aws_kms_key" "eks" {
  count = var.enable_cluster_encryption && var.kms_key_arn == "" ? 1 : 0

  description             = "EKS Cluster ${local.cluster_name} encryption key"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = merge(
    var.tags,
    {
      Name = "${local.cluster_name}-kms"
    }
  )
}

resource "aws_kms_alias" "eks" {
  count = var.enable_cluster_encryption && var.kms_key_arn == "" ? 1 : 0

  name          = "alias/${local.cluster_name}"
  target_key_id = aws_kms_key.eks[0].key_id
}

# Security Group for EKS Cluster
resource "aws_security_group" "cluster" {
  name        = "${local.cluster_name}-cluster-sg"
  description = "Security group for ${local.cluster_name} cluster"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${local.cluster_name}-cluster-sg"
    }
  )
}

# Security Group Rules for Cluster
resource "aws_security_group_rule" "cluster_ingress_workstation_https" {
  count = length(var.cluster_endpoint_public_access_cidrs) > 0 ? 1 : 0

  description       = "Allow workstation to communicate with the cluster API Server"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.cluster_endpoint_public_access_cidrs
  security_group_id = aws_security_group.cluster.id
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = var.cluster_iam_role_arn

  vpc_config {
    subnet_ids              = concat(var.public_subnet_ids, var.private_subnet_ids)
    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
    security_group_ids      = [aws_security_group.cluster.id]
  }

  encryption_config {
    provider {
      key_arn = var.enable_cluster_encryption ? (
        var.kms_key_arn != "" ? var.kms_key_arn : aws_kms_key.eks[0].arn
      ) : ""
    }
    resources = ["secrets"]
  }

  enabled_cluster_log_types = var.cluster_log_types

  tags = merge(
    var.tags,
    {
      Name = local.cluster_name
    }
  )

  depends_on = [
    aws_cloudwatch_log_group.cluster
  ]
}

# CloudWatch Log Group for EKS Cluster
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = var.tags
}

# Security Group for Node Groups
resource "aws_security_group" "node" {
  name        = "${local.cluster_name}-node-sg"
  description = "Security group for ${local.cluster_name} nodes"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name                                        = "${local.cluster_name}-node-sg"
      "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    }
  )
}

# Security Group Rules for Nodes
resource "aws_security_group_rule" "node_ingress_self" {
  description              = "Allow nodes to communicate with each other"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "node_ingress_cluster" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.node.id
}

resource "aws_security_group_rule" "cluster_ingress_node_https" {
  description              = "Allow pods to communicate with the cluster API Server"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.cluster.id
}

# Launch Template for Node Group
resource "aws_launch_template" "node_group" {
  name_prefix = "${local.cluster_name}-node-"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
      kms_key_id           = var.enable_cluster_encryption ? (
        var.kms_key_arn != "" ? var.kms_key_arn : aws_kms_key.eks[0].arn
      ) : ""
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups            = [aws_security_group.node.id]
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      var.tags,
      {
        Name = "${local.cluster_name}-node"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(
      var.tags,
      {
        Name = "${local.cluster_name}-node-volume"
      }
    )
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    cluster_name        = aws_eks_cluster.main.name
    cluster_endpoint    = aws_eks_cluster.main.endpoint
    cluster_ca          = aws_eks_cluster.main.certificate_authority[0].data
    region              = var.region
    additional_userdata = var.node_group_additional_userdata
  }))

  tags = var.tags
}

# EKS Node Group
resource "aws_eks_node_group" "main" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = each.key
  node_role_arn   = var.node_group_iam_role_arn
  subnet_ids      = var.private_subnet_ids
  version         = var.cluster_version

  scaling_config {
    desired_size = each.value.desired_size
    max_size     = each.value.max_size
    min_size     = each.value.min_size
  }

  update_config {
    max_unavailable_percentage = 25
  }

  launch_template {
    id      = aws_launch_template.node_group.id
    version = aws_launch_template.node_group.latest_version
  }

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type

  labels = merge(
    {
      "node-group" = each.key
      "capacity-type" = each.value.capacity_type
    },
    each.value.labels
  )

  taints = each.value.taints

  tags = merge(
    var.tags,
    {
      Name = "${local.cluster_name}-${each.key}"
    },
    each.value.tags
  )

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# OIDC Provider URL
data "aws_eks_cluster" "main" {
  name = aws_eks_cluster.main.name
}

# EKS Addons
resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  addon_version            = var.vpc_cni_version
  resolve_conflicts        = "OVERWRITE"
  service_account_role_arn = var.enable_irsa ? var.vpc_cni_role_arn : null

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name      = aws_eks_cluster.main.name
  addon_name        = "kube-proxy"
  addon_version     = var.kube_proxy_version
  resolve_conflicts = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "core_dns" {
  cluster_name      = aws_eks_cluster.main.name
  addon_name        = "coredns"
  addon_version     = var.coredns_version
  resolve_conflicts = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "ebs_csi_driver" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = var.ebs_csi_driver_version
  resolve_conflicts        = "OVERWRITE"
  service_account_role_arn = var.enable_irsa ? var.ebs_csi_driver_role_arn : null

  tags = var.tags
}