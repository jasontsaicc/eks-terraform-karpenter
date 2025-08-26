# Karpenter CrashLoopBackOff 故障排除報告

## 問題摘要
Karpenter Pod 持續處於 CrashLoopBackOff 狀態，主要問題如下：

### 1. 初始問題（v0.16.3）
- **錯誤**: `panic: "" not a valid CLUSTER_ENDPOINT URL`
- **原因**: 缺少 CLUSTER_ENDPOINT 環境變數
- **狀態**: 已通過升級版本解決

### 2. CRD 版本不匹配（v1.0.2）
- **錯誤**: `panic: failed to setup nodeclaim provider id indexer: no matches for kind "NodeClaim"`
- **原因**: CRD 版本與 Karpenter 版本不匹配
- **狀態**: 已安裝正確版本的 CRDs

### 3. IAM 權限問題（v1.0.6）- 已解決
- **錯誤**: `WebIdentityErr: failed to retrieve credentials - AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`
- **原因**: IAM 角色信任策略配置錯誤
- **狀態**: ✅ 已修復
- **解決方案**: 更新信任策略並添加必要的權限（EKS, SQS, EC2）

## 根本原因分析

### IAM 角色信任策略問題
原始信任策略指向錯誤的 namespace：
```json
{
  "Condition": {
    "StringEquals": {
      "...sub": "system:serviceaccount:karpenter:karpenter"  // 錯誤
    }
  }
}
```

應該是：
```json
{
  "Condition": {
    "StringEquals": {
      "...sub": "system:serviceaccount:kube-system:karpenter"  // 正確
    }
  }
}
```

## 解決方案

### 方案 1：修復現有 IAM 角色
```bash
# 更新信任策略
cat <<EOF > /tmp/trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::273528188825:oidc-provider/oidc.eks.ap-southeast-1.amazonaws.com/id/3F1AA6C6B518B869FDDAFD647F3DEFB4"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.ap-southeast-1.amazonaws.com/id/3F1AA6C6B518B869FDDAFD647F3DEFB4:sub": "system:serviceaccount:kube-system:karpenter",
          "oidc.eks.ap-southeast-1.amazonaws.com/id/3F1AA6C6B518B869FDDAFD647F3DEFB4:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam update-assume-role-policy \
  --role-name KarpenterControllerRole-eks-lab-test-eks \
  --policy-document file:///tmp/trust-policy.json
```

### 方案 2：使用 eksctl 創建新角色（推薦）
```bash
eksctl create iamserviceaccount \
  --cluster eks-lab-test-eks \
  --namespace kube-system \
  --name karpenter \
  --role-name KarpenterControllerRole-New \
  --attach-policy-arn arn:aws:iam::aws:policy/PowerUserAccess \
  --override-existing-serviceaccounts \
  --approve
```

### 方案 3：在 karpenter namespace 部署
```bash
# 創建 karpenter namespace
kubectl create namespace karpenter

# 重新安裝 Karpenter 到原始 namespace
helm uninstall karpenter -n kube-system

helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "1.0.6" \
  --namespace karpenter \
  --create-namespace \
  --set "settings.clusterName=eks-lab-test-eks" \
  --set "settings.interruptionQueue=eks-lab-test-eks" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::273528188825:role/KarpenterControllerRole-eks-lab-test-eks" \
  --wait
```

## 驗證步驟

1. **檢查 Pod 狀態**
```bash
kubectl get pods -n kube-system | grep karpenter
```

2. **檢查日誌**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50
```

3. **測試 IAM 權限**
```bash
kubectl run aws-cli --rm -it --image=amazon/aws-cli \
  --serviceaccount=karpenter \
  --namespace=kube-system \
  -- sts get-caller-identity
```

## 預防措施

1. **使用正確的 namespace**
   - 官方建議在 `karpenter` namespace 安裝
   - 如果使用 `kube-system`，確保 IAM 角色配置正確

2. **版本匹配**
   - Karpenter 版本與 CRDs 版本必須匹配
   - 使用官方推薦的版本組合

3. **IAM 角色驗證**
   - 部署前驗證 OIDC provider 正確配置
   - 確保信任策略的 namespace 與實際部署一致

## 最終工作配置

### 成功部署的配置
- **Karpenter 版本**: 1.0.6
- **Namespace**: kube-system
- **Helm Chart**: oci://public.ecr.aws/karpenter/karpenter
- **必要的 IAM 權限**:
  - EC2 (CreateFleet, RunInstances, TerminateInstances 等)
  - EKS (DescribeCluster)
  - SQS (GetQueueUrl, ReceiveMessage, DeleteMessage)
  - IAM (PassRole, CreateInstanceProfile)
  - SSM (GetParameter)
  - Pricing (GetProducts)

### 資源標記要求
- 子網路必須標記: `karpenter.sh/discovery: <cluster-name>`
- 安全群組必須標記: `karpenter.sh/discovery: <cluster-name>`

### 驗證成功部署
```bash
# 檢查 Karpenter Pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# 檢查 NodePool
kubectl get nodepools -A

# 檢查 EC2NodeClass
kubectl get ec2nodeclasses -A

# 檢查 NodeClaim（當有 Pod 需要調度時）
kubectl get nodeclaims -A
```

## 參考資源
- [Karpenter 官方文檔](https://karpenter.sh/docs/)
- [AWS Karpenter Provider v1.0.6](https://github.com/aws/karpenter-provider-aws/releases/tag/v1.0.6)
- [故障排除指南](https://karpenter.sh/docs/troubleshooting/)

---
**報告日期**: 2025-08-25
**作者**: jasontsai
**最後更新**: 2025-08-25 - 成功修復所有問題並部署 Karpenter v1.0.6