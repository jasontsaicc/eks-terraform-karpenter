# 故障排除完整指南

## 目錄
1. [EKS 集群問題](#eks-集群問題)
2. [Karpenter 問題](#karpenter-問題)
3. [網路問題](#網路問題)
4. [IAM 和權限問題](#iam-和權限問題)
5. [負載均衡器問題](#負載均衡器問題)
6. [GitOps 問題](#gitops-問題)
7. [成本和資源問題](#成本和資源問題)
8. [診斷工具和命令](#診斷工具和命令)

## EKS 集群問題

### 問題：集群無法創建
**症狀**：
- Terraform apply 失敗
- EKS 集群狀態顯示 FAILED

**解決方案**：
```bash
# 1. 檢查 IAM 權限
aws sts get-caller-identity

# 2. 檢查服務配額
aws service-quotas get-service-quota \
  --service-code eks \
  --quota-code L-1194D53C

# 3. 檢查 VPC 配置
aws ec2 describe-vpcs --vpc-ids ${VPC_ID}

# 4. 重試部署
terraform destroy -target=module.eks
terraform apply -target=module.eks
```

### 問題：無法連接到集群
**症狀**：
- kubectl 命令超時
- Unable to connect to the server

**解決方案**：
```bash
# 1. 更新 kubeconfig
aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}

# 2. 檢查集群端點
aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.endpoint'

# 3. 檢查安全組
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*${CLUSTER_NAME}*"

# 4. 測試連接
kubectl get nodes --v=9
```

## Karpenter 問題

### 問題：節點無法加入集群
**症狀**：
- Karpenter 創建實例但節點狀態為 NotReady
- 節點無法註冊到 EKS

**根本原因**：
- 安全組規則不正確
- IAM 角色權限不足
- User Data 腳本錯誤
- 網路連通性問題

**解決方案**：

#### 1. 修復安全組
```bash
# 獲取安全組 ID
CLUSTER_SG=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)

NODE_SG=$(aws ec2 describe-security-groups \
  --filters "Name=tag:karpenter.sh/cluster,Values=${CLUSTER_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text)

# 添加必要規則
aws ec2 authorize-security-group-ingress \
  --group-id ${CLUSTER_SG} \
  --source-group ${NODE_SG} \
  --protocol all

aws ec2 authorize-security-group-ingress \
  --group-id ${NODE_SG} \
  --source-group ${CLUSTER_SG} \
  --protocol all
```

#### 2. 驗證 IAM 角色
```bash
# 檢查角色信任關係
aws iam get-role --role-name KarpenterNodeRole \
  --query 'Role.AssumeRolePolicyDocument'

# 確保包含 ec2.amazonaws.com
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Service": "ec2.amazonaws.com"
    },
    "Action": "sts:AssumeRole"
  }]
}
```

#### 3. 修復 User Data
```bash
# 更新 NodePool 配置
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      userData: |
        #!/bin/bash
        /etc/eks/bootstrap.sh ${CLUSTER_NAME}
        systemctl restart kubelet
EOF
```

### 問題：Karpenter 不創建節點
**症狀**：
- Pod 處於 Pending 狀態
- Karpenter 日誌顯示無錯誤

**解決方案**：
```bash
# 1. 檢查 NodePool 配置
kubectl get nodepools
kubectl describe nodepool default

# 2. 檢查 EC2 限制
kubectl get nodeclaims
kubectl describe nodeclaim

# 3. 查看 Karpenter 日誌
kubectl logs -n karpenter deployment/karpenter --tail=100

# 4. 檢查實例配額
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-34B43A08
```

## 網路問題

### 問題：Pod 無法訪問互聯網
**症狀**：
- Pod 內無法 curl 外部 URL
- Docker pull 失敗

**解決方案**：
```bash
# 1. 檢查 NAT Gateway
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=${VPC_ID}"

# 2. 檢查路由表
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}"

# 3. 測試 DNS
kubectl run test-pod --image=busybox --rm -it -- nslookup google.com

# 4. 檢查安全組出站規則
aws ec2 describe-security-groups --group-ids ${NODE_SG} \
  --query 'SecurityGroups[0].IpPermissionsEgress'
```

### 問題：Service 無法訪問
**症狀**：
- ClusterIP Service 無法連接
- Pod 間通信失敗

**解決方案**：
```bash
# 1. 檢查 CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system deployment/coredns

# 2. 檢查網路策略
kubectl get networkpolicies -A

# 3. 測試 Service 連接
kubectl run test --image=nicolaka/netshoot --rm -it -- \
  curl service-name.namespace.svc.cluster.local
```

## IAM 和權限問題

### 問題：IRSA 不工作
**症狀**：
- Pod 無法訪問 AWS 資源
- AccessDenied 錯誤

**解決方案**：
```bash
# 1. 檢查 OIDC Provider
aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.identity.oidc.issuer'

# 2. 驗證 ServiceAccount 註解
kubectl get sa -n namespace service-account-name -o yaml

# 3. 檢查 IAM 角色信任策略
aws iam get-role --role-name role-name \
  --query 'Role.AssumeRolePolicyDocument'

# 4. 測試權限
kubectl run aws-cli --rm -it \
  --image=amazon/aws-cli \
  --serviceaccount=service-account-name \
  -- sts get-caller-identity
```

## 負載均衡器問題

### 問題：ALB 無法創建
**症狀**：
- Ingress 狀態為空
- 無 ALB 地址

**解決方案**：
```bash
# 1. 檢查 AWS Load Balancer Controller
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller

# 2. 檢查子網標籤
aws ec2 describe-subnets --subnet-ids ${SUBNET_ID} \
  --query 'Subnets[0].Tags'

# 公有子網需要：
# kubernetes.io/role/elb = 1
# 私有子網需要：
# kubernetes.io/role/internal-elb = 1

# 3. 添加標籤
aws ec2 create-tags --resources ${SUBNET_ID} \
  --tags Key=kubernetes.io/role/elb,Value=1

# 4. 重新創建 Ingress
kubectl delete ingress ingress-name
kubectl apply -f ingress.yaml
```

## GitOps 問題

### 問題：ArgoCD 同步失敗
**症狀**：
- Application 狀態為 OutOfSync
- 同步錯誤

**解決方案**：
```bash
# 1. 檢查 ArgoCD 狀態
kubectl get applications -n argocd

# 2. 查看同步錯誤
argocd app get app-name --show-conditions

# 3. 手動同步
argocd app sync app-name --force

# 4. 檢查 Git 權限
kubectl get secret -n argocd repo-secret -o yaml
```

## 成本和資源問題

### 問題：成本過高
**症狀**：
- AWS 帳單超出預期
- 大量閒置資源

**解決方案**：
```bash
# 1. 檢查運行中的實例
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/cluster,Values=${CLUSTER_NAME}" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]'

# 2. 優化 Karpenter 配置
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-pool
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["t3.medium", "t3a.medium", "t2.medium"]
  limits:
    cpu: "1000"
    memory: "1000Gi"
  disruption:
    ttlSecondsAfterEmpty: 30
EOF

# 3. 設置自動關機
./scripts/monitor-costs.sh --set-budget 100
```

## 診斷工具和命令

### 綜合診斷腳本
```bash
#!/bin/bash
# 保存為 diagnose.sh

echo "=== EKS Cluster Status ==="
aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.status'

echo "=== Node Status ==="
kubectl get nodes -o wide

echo "=== Pod Status ==="
kubectl get pods -A | grep -v Running

echo "=== Karpenter Status ==="
kubectl get nodepools
kubectl get nodeclaims
kubectl logs -n karpenter deployment/karpenter --tail=20

echo "=== Service Status ==="
kubectl get svc -A | grep LoadBalancer

echo "=== Events ==="
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

echo "=== Resource Usage ==="
kubectl top nodes
kubectl top pods -A | head -20
```

### 常用診斷命令
```bash
# 檢查集群健康
kubectl cluster-info
kubectl get componentstatuses

# 檢查節點問題
kubectl describe node ${NODE_NAME}
kubectl get node ${NODE_NAME} -o yaml | grep -A5 conditions

# 檢查 Pod 問題
kubectl describe pod ${POD_NAME}
kubectl logs ${POD_NAME} --previous
kubectl exec ${POD_NAME} -- env

# 網路診斷
kubectl run netshoot --rm -it --image=nicolaka/netshoot -- /bin/bash

# 資源使用
kubectl top nodes --sort-by=cpu
kubectl top pods -A --sort-by=memory

# 查看最近事件
kubectl get events -A --sort-by='.lastTimestamp'
```

### 緊急恢復程序
```bash
# 1. 重啟有問題的 Pod
kubectl rollout restart deployment/${DEPLOYMENT_NAME}

# 2. 強制刪除卡住的 Pod
kubectl delete pod ${POD_NAME} --force --grace-period=0

# 3. 重置節點
kubectl drain ${NODE_NAME} --ignore-daemonsets --delete-emptydir-data
kubectl uncordon ${NODE_NAME}

# 4. 緊急擴容
kubectl scale deployment ${DEPLOYMENT_NAME} --replicas=5
```

## 預防措施

### 最佳實踐
1. **定期備份**：
   ```bash
   kubectl get all -A -o yaml > backup.yaml
   ```

2. **監控告警**：
   - 設置 CloudWatch 告警
   - 配置 Prometheus 規則

3. **資源限制**：
   - 設置 Pod 資源請求和限制
   - 配置 Karpenter 節點池限制

4. **安全掃描**：
   ```bash
   # 掃描映像漏洞
   trivy image ${IMAGE_NAME}
   ```

---
**最後更新**: 2025-08-25
**維護者**: Jason Tsai