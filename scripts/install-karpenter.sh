#!/bin/bash

# Karpenter 安裝腳本
# 此腳本會安裝和配置 Karpenter 自動擴展器

set -e

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 確保使用 EKS kubeconfig
export KUBECONFIG=~/.kube/config-eks
export CLUSTER_NAME=eks-lab-test-eks
export AWS_DEFAULT_REGION=ap-southeast-1
export AWS_REGION=ap-southeast-1

# 檢查必要工具
check_requirements() {
    log_info "檢查必要工具..."
    
    if ! command -v helm &> /dev/null; then
        log_error "Helm 未安裝，正在安裝..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "無法連接到 Kubernetes 集群"
        exit 1
    fi
    
    log_info "✓ 所有必要工具已就緒"
}

# 創建 OIDC 提供者
create_oidc_provider() {
    log_step "創建 OIDC 提供者..."
    
    # 獲取 OIDC 發行者 URL
    OIDC_ISSUER_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text)
    log_info "OIDC Issuer URL: $OIDC_ISSUER_URL"
    
    # 獲取 OIDC ID
    OIDC_ID=$(echo $OIDC_ISSUER_URL | cut -d '/' -f 5)
    
    # 檢查 OIDC 提供者是否已存在
    if aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '$OIDC_ID')]" --output text | grep -q $OIDC_ID; then
        log_info "OIDC 提供者已存在"
    else
        log_info "創建 OIDC 提供者..."
        # EKS OIDC root CA thumbprint (這是 AWS EKS 的標準指紋)
        THUMBPRINT="9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
        
        aws iam create-open-id-connect-provider \
            --url $OIDC_ISSUER_URL \
            --client-id-list sts.amazonaws.com \
            --thumbprint-list $THUMBPRINT
        
        log_info "✓ OIDC 提供者創建完成"
    fi
}

# 創建 Karpenter IAM 角色
create_karpenter_iam() {
    log_step "創建 Karpenter IAM 角色..."
    
    # 獲取帳戶 ID 和 OIDC ID
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    OIDC_ISSUER_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text)
    OIDC_ID=$(echo $OIDC_ISSUER_URL | cut -d '/' -f 5)
    
    # Karpenter Controller Role
    CONTROLLER_ROLE_NAME="${CLUSTER_NAME}-karpenter-controller"
    if aws iam get-role --role-name $CONTROLLER_ROLE_NAME &>/dev/null; then
        log_info "Karpenter Controller 角色已存在"
    else
        log_info "創建 Karpenter Controller 角色..."
        
        cat > karpenter-controller-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID:sub": "system:serviceaccount:karpenter:karpenter",
                    "oidc.eks.$AWS_REGION.amazonaws.com/id/$OIDC_ID:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF
        
        aws iam create-role \
            --role-name $CONTROLLER_ROLE_NAME \
            --assume-role-policy-document file://karpenter-controller-trust-policy.json
        
        # 附加 Karpenter Controller 策略
        cat > karpenter-controller-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowScopedEC2InstanceAccessActions",
            "Effect": "Allow",
            "Resource": [
                "arn:aws:ec2:$AWS_REGION::image/*",
                "arn:aws:ec2:$AWS_REGION::snapshot/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:security-group/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:subnet/*"
            ],
            "Action": [
                "ec2:RunInstances",
                "ec2:CreateFleet"
            ]
        },
        {
            "Sid": "AllowScopedEC2LaunchTemplateAccessActions",
            "Effect": "Allow",
            "Resource": "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:launch-template/*",
            "Action": [
                "ec2:RunInstances",
                "ec2:CreateFleet",
                "ec2:CreateLaunchTemplate",
                "ec2:CreateLaunchTemplateVersion",
                "ec2:ModifyLaunchTemplate",
                "ec2:DeleteLaunchTemplate",
                "ec2:DeleteLaunchTemplateVersions"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                },
                "StringLike": {
                    "aws:RequestTag/karpenter.sh/cluster": "$CLUSTER_NAME"
                }
            }
        },
        {
            "Sid": "AllowScopedEC2InstanceActionsWithTags",
            "Effect": "Allow",
            "Resource": [
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:fleet/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:instance/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:volume/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:network-interface/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:launch-template/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:spot-instances-request/*"
            ],
            "Action": [
                "ec2:RunInstances",
                "ec2:CreateFleet",
                "ec2:CreateLaunchTemplate",
                "ec2:CreateLaunchTemplateVersion",
                "ec2:ModifyLaunchTemplate",
                "ec2:DeleteLaunchTemplate",
                "ec2:DeleteLaunchTemplateVersions",
                "ec2:TerminateInstances",
                "ec2:CreateTags"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                },
                "StringLike": {
                    "aws:RequestTag/karpenter.sh/cluster": "$CLUSTER_NAME"
                }
            }
        },
        {
            "Sid": "AllowScopedResourceCreationTagging",
            "Effect": "Allow",
            "Resource": [
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:fleet/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:instance/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:volume/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:network-interface/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:launch-template/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:spot-instances-request/*"
            ],
            "Action": "ec2:CreateTags",
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION",
                    "ec2:CreateAction": [
                        "RunInstances",
                        "CreateFleet",
                        "CreateLaunchTemplate"
                    ]
                },
                "StringLike": {
                    "aws:RequestTag/karpenter.sh/cluster": "$CLUSTER_NAME"
                }
            }
        },
        {
            "Sid": "AllowScopedResourceTagging",
            "Effect": "Allow",
            "Resource": "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:instance/*",
            "Action": "ec2:CreateTags",
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                },
                "StringLike": {
                    "aws:ResourceTag/karpenter.sh/cluster": "$CLUSTER_NAME"
                },
                "ForAllValues:StringEquals": {
                    "aws:TagKeys": [
                        "karpenter.sh/nodeclaim",
                        "Name"
                    ]
                }
            }
        },
        {
            "Sid": "AllowScopedDeletion",
            "Effect": "Allow",
            "Resource": [
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:instance/*",
                "arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:launch-template/*"
            ],
            "Action": [
                "ec2:TerminateInstances",
                "ec2:DeleteLaunchTemplate",
                "ec2:DeleteLaunchTemplateVersions"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                },
                "StringLike": {
                    "aws:ResourceTag/karpenter.sh/cluster": "$CLUSTER_NAME"
                }
            }
        },
        {
            "Sid": "AllowRegionalReadActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeImages",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceTypeOfferings",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeLaunchTemplates",
                "ec2:DescribeLaunchTemplateVersions",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSpotPriceHistory",
                "ec2:DescribeSubnets"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                }
            }
        },
        {
            "Sid": "AllowSSMReadActions",
            "Effect": "Allow",
            "Resource": "arn:aws:ssm:$AWS_REGION::parameter/aws/service/*",
            "Action": "ssm:GetParameter"
        },
        {
            "Sid": "AllowPricingReadActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": "pricing:GetProducts"
        },
        {
            "Sid": "AllowInterruptionQueueActions",
            "Effect": "Allow",
            "Resource": "arn:aws:sqs:$AWS_REGION:$ACCOUNT_ID:Karpenter-$CLUSTER_NAME",
            "Action": [
                "sqs:DeleteMessage",
                "sqs:GetQueueUrl",
                "sqs:GetQueueAttributes",
                "sqs:ReceiveMessage"
            ]
        },
        {
            "Sid": "AllowPassingInstanceRole",
            "Effect": "Allow",
            "Resource": "arn:aws:iam::$ACCOUNT_ID:role/KarpenterNodeInstanceProfile-$CLUSTER_NAME",
            "Action": "iam:PassRole",
            "Condition": {
                "StringEquals": {
                    "iam:PassedToService": "ec2.amazonaws.com"
                }
            }
        },
        {
            "Sid": "AllowScopedInstanceProfileCreationActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
                "iam:CreateInstanceProfile"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                },
                "StringLike": {
                    "aws:RequestTag/karpenter.sh/cluster": "$CLUSTER_NAME",
                    "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
                }
            }
        },
        {
            "Sid": "AllowScopedInstanceProfileTagActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
                "iam:TagInstanceProfile"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                },
                "StringLike": {
                    "aws:ResourceTag/karpenter.sh/cluster": "$CLUSTER_NAME",
                    "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*",
                    "aws:RequestTag/karpenter.sh/cluster": "$CLUSTER_NAME",
                    "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass": "*"
                }
            }
        },
        {
            "Sid": "AllowScopedInstanceProfileActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": [
                "iam:AddRoleToInstanceProfile",
                "iam:RemoveRoleFromInstanceProfile",
                "iam:DeleteInstanceProfile"
            ],
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "$AWS_REGION"
                },
                "StringLike": {
                    "aws:ResourceTag/karpenter.sh/cluster": "$CLUSTER_NAME",
                    "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass": "*"
                }
            }
        },
        {
            "Sid": "AllowInstanceProfileReadActions",
            "Effect": "Allow",
            "Resource": "*",
            "Action": "iam:GetInstanceProfile"
        },
        {
            "Sid": "AllowAPIServerEndpointDiscovery",
            "Effect": "Allow",
            "Resource": "arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME",
            "Action": "eks:DescribeCluster"
        }
    ]
}
EOF
        
        aws iam put-role-policy \
            --role-name $CONTROLLER_ROLE_NAME \
            --policy-name KarpenterControllerPolicy \
            --policy-document file://karpenter-controller-policy.json
        
        log_info "✓ Karpenter Controller 角色創建完成"
    fi
    
    # Karpenter Node Instance Profile
    NODE_INSTANCE_PROFILE_NAME="KarpenterNodeInstanceProfile-$CLUSTER_NAME"
    if aws iam get-instance-profile --instance-profile-name $NODE_INSTANCE_PROFILE_NAME &>/dev/null; then
        log_info "Karpenter Node Instance Profile 已存在"
    else
        log_info "創建 Karpenter Node Instance Profile..."
        
        # 創建 Node 角色
        NODE_ROLE_NAME="KarpenterNodeInstanceProfile-$CLUSTER_NAME"
        
        cat > karpenter-node-trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
        
        aws iam create-role \
            --role-name $NODE_ROLE_NAME \
            --assume-role-policy-document file://karpenter-node-trust-policy.json
        
        # 附加必要的 AWS 管理策略
        aws iam attach-role-policy \
            --role-name $NODE_ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        
        aws iam attach-role-policy \
            --role-name $NODE_ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        
        aws iam attach-role-policy \
            --role-name $NODE_ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        
        aws iam attach-role-policy \
            --role-name $NODE_ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
        
        # 創建 Instance Profile
        aws iam create-instance-profile --instance-profile-name $NODE_INSTANCE_PROFILE_NAME
        aws iam add-role-to-instance-profile \
            --instance-profile-name $NODE_INSTANCE_PROFILE_NAME \
            --role-name $NODE_ROLE_NAME
        
        log_info "✓ Karpenter Node Instance Profile 創建完成"
    fi
    
    # 清理臨時文件
    rm -f karpenter-controller-trust-policy.json karpenter-controller-policy.json karpenter-node-trust-policy.json
}

# 安裝 Karpenter
install_karpenter() {
    log_step "安裝 Karpenter..."
    
    # 添加 Karpenter Helm repository
    helm repo add karpenter https://charts.karpenter.sh/
    helm repo update
    
    # 創建 karpenter 命名空間
    kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -
    
    # 獲取 Controller Role ARN
    CONTROLLER_ROLE_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/${CLUSTER_NAME}-karpenter-controller"
    
    # 安裝 Karpenter
    helm upgrade --install karpenter karpenter/karpenter \
        --namespace karpenter \
        --create-namespace \
        --version "0.37.0" \
        --set "settings.clusterName=${CLUSTER_NAME}" \
        --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${CONTROLLER_ROLE_ARN}" \
        --set controller.resources.requests.cpu=1 \
        --set controller.resources.requests.memory=1Gi \
        --set controller.resources.limits.cpu=1 \
        --set controller.resources.limits.memory=1Gi \
        --wait
    
    log_info "✓ Karpenter 安裝完成"
}

# 創建 Karpenter NodePool 和 EC2NodeClass
create_karpenter_resources() {
    log_step "創建 Karpenter 資源..."
    
    # 獲取子網 ID
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
              "Name=tag:Name,Values=*private*" \
        --query 'Subnets[].SubnetId' \
        --output text | tr '\t' ',')
    
    # 獲取安全組 ID
    SECURITY_GROUP_ID=$(terraform output -raw cluster_security_group_id)
    
    # 創建 EC2NodeClass
    cat > ec2nodeclass.yaml << EOF
apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: default
spec:
  # Reference the instance profile created above
  instanceProfile: "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
  
  # Specify subnets in your cluster's VPC
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  
  # Specify the security groups of the nodes
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  
  # Optional: Specify instance types, architecture, etc.
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot", "on-demand"]
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64"]
  
  # Specify the AMI family which dictates the bootstrapping logic
  amiFamily: AL2023
  
  # Configure user data for bootstrapping
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh ${CLUSTER_NAME}
    
  # Optional: Enable detailed monitoring
  detailedMonitoring: true
  
  # Optional: Configure block device mappings
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 20Gi
        volumeType: gp3
        deleteOnTermination: true
        encrypted: true
EOF
    
    # 創建 NodePool
    cat > nodepool.yaml << EOF
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: default
spec:
  # Template section that describes the nodes that will be created
  template:
    metadata:
      # Labels that will be applied to all nodes, in addition to the defaults
      labels:
        node-type: "karpenter"
    
    spec:
      # References the EC2NodeClass above
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: default
      
      # Provisioned nodes will have these taints
      # Taints may prevent pods from scheduling if they are not tolerated
      # taints:
      #   - key: example.com/special-taint
      #     effect: NoSchedule
      
      # Provisioned nodes will have these taints, but pods do not need to tolerate these taints to be provisioned by this
      # NodePool. These taints are expected to be temporary and some other entity (e.g. a DaemonSet) is responsible for
      # removing the taint after it has finished initializing the node.
      startupTaints:
        - key: example.com/another-taint
          effect: NoSchedule
      
      # Requirements that constrain the parameters of provisioned nodes
      # These requirements are combined with pod.spec.affinity.nodeAffinity rules.
      # Operators { In, NotIn } are supported to enable including or excluding values
      requirements:
        # Include general purpose instance families
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In  
          values: ["t3.medium", "t3.large", "t3.xlarge", "c5.large", "c5.xlarge", "m5.large", "m5.xlarge"]
  
  # Disruption section which describes the ways in which Karpenter can disrupt and replace Nodes
  # Configuration in this section constrains how aggressive Karpenter can be with performing operations
  # like rolling Nodes due to them hitting their maximum lifetime (expiry) or scaling down nodes to reduce cluster cost
  disruption:
    # Describes which types of Nodes Karpenter should consider for consolidation
    # If using 'WhenUnderutilized', Karpenter will consider all nodes for consolidation and attempt to remove or replace Nodes when it discovers that the Node is underutilized and could be changed to reduce cost
    # If using 'WhenEmpty', Karpenter will only consider nodes for consolidation that contain no workload pods
    consolidationPolicy: WhenEmpty
    
    # The amount of time Karpenter should wait after discovering a consolidation decision
    # This value can currently only be set when the consolidationPolicy is 'WhenEmpty'
    # You can choose to disable consolidation entirely by setting the string value 'Never' here
    consolidateAfter: 30s
    
    # The amount of time a Node can live on the cluster before being removed
    # Avoiding long-running Nodes helps to reduce security vulnerabilities as well as to reduce the chance of issues that can plague Nodes with long uptimes such as file fragmentation or memory leaks from system processes
    # You can choose to disable expiry entirely by setting the string value 'Never' here
    expireAfter: Never

  # Resource limits constrain the total size of the pool.
  # Limits prevent Karpenter from creating new instances once the limit is exceeded.
  limits:
    cpu: 1000
    memory: 1000Gi
EOF
    
    # 應用資源
    kubectl apply -f ec2nodeclass.yaml
    kubectl apply -f nodepool.yaml
    
    log_info "✓ Karpenter 資源創建完成"
    
    # 清理臨時文件
    rm -f ec2nodeclass.yaml nodepool.yaml
}

# 驗證 Karpenter 安裝
verify_karpenter() {
    log_step "驗證 Karpenter 安裝..."
    
    # 檢查 Pod 狀態
    kubectl get pods -n karpenter
    
    # 檢查 Karpenter 資源
    kubectl get nodepool
    kubectl get ec2nodeclass
    
    log_info "✓ Karpenter 驗證完成"
}

# 主函數
main() {
    log_info "開始 Karpenter 安裝流程..."
    
    check_requirements
    create_oidc_provider
    create_karpenter_iam
    install_karpenter
    create_karpenter_resources
    verify_karpenter
    
    log_info "🎉 Karpenter 安裝完成！"
    
    echo ""
    echo "下一步："
    echo "1. 部署測試工作負載來觸發 Karpenter 自動擴展"
    echo "2. 監控 Karpenter 日誌: kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter"
    echo "3. 檢查節點自動創建: kubectl get nodes --watch"
}

# 執行主函數
main "$@"