# EKS 安全最佳實踐

## 🔒 網路安全

### 1. VPC 和子網路設計
- **私有子網路**: 所有 EKS 節點部署在私有子網路
- **公開子網路**: 僅用於 Load Balancer 和 NAT Gateway
- **網路分段**: 使用多個子網路實現網路隔離
- **CIDR 規劃**: 使用適當大小的 CIDR 避免 IP 衝突

### 2. 安全群組規則
```hcl
# 集群安全群組 - 最小權限原則
resource "aws_security_group_rule" "cluster_egress_internet" {
  description       = "Allow all outbound traffic"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
}

# 節點安全群組 - 僅允許必要流量
resource "aws_security_group_rule" "node_ingress_cluster_443" {
  description              = "Allow pods to communicate with cluster API"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id
  security_group_id        = aws_security_group.node.id
}
```

### 3. 網路政策
```yaml
# 預設拒絕所有流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
# 允許特定應用通訊
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-traffic
spec:
  podSelector:
    matchLabels:
      app: web-app
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
```

## 🔐 身份驗證與授權

### 1. RBAC 配置
```yaml
# 最小權限服務帳戶
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-service-account
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/app-role
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: default
subjects:
- kind: ServiceAccount
  name: app-service-account
  namespace: default
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### 2. IRSA (IAM Roles for Service Accounts)
```hcl
# 應用專用 IAM 角色
resource "aws_iam_role" "app_role" {
  name = "eks-app-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:default:app-service-account"
        }
      }
    }]
  })
}

# 最小權限政策
resource "aws_iam_role_policy" "app_policy" {
  name = "app-s3-policy"
  role = aws_iam_role.app_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject"
      ]
      Resource = "arn:aws:s3:::my-app-bucket/*"
    }]
  })
}
```

## 🛡️ Pod 安全

### 1. Pod Security Standards
```yaml
# Pod Security Policy 替代 - Pod Security Standards
apiVersion: v1
kind: Namespace
metadata:
  name: secure-namespace
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### 2. Security Context
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 2000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: nginx:1.20
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 1000
          capabilities:
            drop:
            - ALL
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
          requests:
            memory: "128Mi"
            cpu: "100m"
        volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
        - name: var-run-volume
          mountPath: /var/run
      volumes:
      - name: tmp-volume
        emptyDir: {}
      - name: var-run-volume
        emptyDir: {}
```

## 🔍 監控與日誌

### 1. Audit 日誌
```yaml
# EKS Audit Policy
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  namespaces: ["kube-system", "kube-public", "kube-node-lease"]
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]
- level: Request
  verbs: ["create", "update", "patch", "delete"]
```

### 2. 資源監控
```yaml
# 監控異常活動
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kubernetes-security-alerts
spec:
  groups:
  - name: kubernetes-security
    rules:
    - alert: PodSecurityViolation
      expr: increase(pod_security_violations_total[5m]) > 0
      for: 0m
      labels:
        severity: warning
      annotations:
        summary: "Pod security violation detected"
    
    - alert: PrivilegedContainerStarted
      expr: kube_pod_container_status_running{container=~".*"} and on(pod) kube_pod_spec_containers_security_context_privileged == 1
      for: 0m
      labels:
        severity: critical
      annotations:
        summary: "Privileged container started"
```

## 🔒 資料加密

### 1. 傳輸加密
- **TLS 1.2+**: 所有通訊使用 TLS 1.2 或更高版本
- **mTLS**: 服務間通訊使用相互 TLS 認證
- **Ingress TLS**: 使用有效的 SSL 憑證

### 2. 靜態加密
```hcl
# EKS Secrets 加密
resource "aws_eks_cluster" "main" {
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }
}

# EBS 磁碟加密
resource "aws_launch_template" "node_group" {
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted             = true
      kms_key_id           = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }
}
```

## 🚨 事件回應

### 1. 安全事件偵測
```bash
# 檢查異常 Pod
kubectl get pods --all-namespaces -o wide | grep -E "(Evicted|Error|CrashLoopBackOff)"

# 檢查特權容器
kubectl get pods --all-namespaces -o json | jq '.items[] | select(.spec.containers[]?.securityContext.privileged == true) | .metadata.name'

# 檢查外部網路連接
kubectl logs -l app=network-monitor -n monitoring | grep -E "(EXTERNAL|SUSPICIOUS)"
```

### 2. 自動回應腳本
```bash
#!/bin/bash
# security-response.sh

# 隔離可疑 Pod
isolate_pod() {
    local pod_name=$1
    local namespace=$2
    
    # 添加網路政策阻斷流量
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-${pod_name}
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      name: ${pod_name}
  policyTypes:
  - Ingress
  - Egress
EOF
}

# 收集證據
collect_evidence() {
    local pod_name=$1
    local namespace=$2
    
    kubectl logs ${pod_name} -n ${namespace} > evidence/${pod_name}_logs.txt
    kubectl describe pod ${pod_name} -n ${namespace} > evidence/${pod_name}_describe.txt
}
```

## 📋 安全檢查清單

### 部署前檢查
- [ ] 所有 Docker 映像檔已掃描漏洞
- [ ] RBAC 規則遵循最小權限原則
- [ ] Network Policies 已配置
- [ ] Pod Security Standards 已啟用
- [ ] Secrets 使用外部密鑰管理

### 定期安全稽核
- [ ] 檢視 RBAC 權限
- [ ] 更新容器映像檔
- [ ] 審查網路政策
- [ ] 監控異常活動
- [ ] 測試災難恢復程序