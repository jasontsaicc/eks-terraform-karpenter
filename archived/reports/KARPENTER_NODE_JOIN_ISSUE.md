# Karpenter 節點無法加入 EKS 集群問題

## 問題描述
Karpenter v1.0.6 成功安裝並能夠創建 EC2 實例，但節點無法加入 EKS 集群。

## 當前狀態

### ✅ 工作正常的部分
1. Karpenter Pods 運行正常
2. NodePool 和 EC2NodeClass 配置正確
3. IAM 權限配置完整
4. 成功創建 EC2 實例
5. SQS 隊列配置正確

### ❌ 問題部分
1. EC2 實例無法註冊為 Kubernetes 節點
2. NodeClaim 狀態顯示 "Node not registered with cluster"
3. Pod 持續處於 Pending 狀態

## 診斷結果

### NodeClaim 狀態
```
NAME                    TYPE       CAPACITY   ZONE              NODE   READY     AGE
general-purpose-h9kq2   t3.large   spot       ap-southeast-1b          Unknown   30m
```

### EC2 實例狀態
- 實例狀態：Running
- 私有 IP：10.0.11.25
- 子網：subnet-0314bda17e8a25f08 (私有子網)
- Instance Profile：正確附加

## 根本原因分析

### 1. 網絡連接問題（最可能）
節點需要能夠連接到 EKS API endpoint，可能的問題：
- NAT Gateway 配置問題
- 安全群組規則不允許出站 HTTPS (443)
- DNS 解析問題

### 2. UserData 腳本問題
當前 UserData：
```bash
#!/bin/bash
/etc/eks/bootstrap.sh eks-lab-test-eks
```

可能需要額外參數：
```bash
#!/bin/bash
/etc/eks/bootstrap.sh eks-lab-test-eks \
  --b64-cluster-ca <CA證書> \
  --apiserver-endpoint <API端點>
```

### 3. IAM 權限問題
節點角色可能缺少權限：
- `eks:DescribeCluster`
- 加入集群所需的其他權限

## 解決方案

### 方案 1：驗證網絡連接
```bash
# 檢查 NAT Gateway 路由
aws ec2 describe-route-tables --region ap-southeast-1 \
  --filters "Name=association.subnet-id,Values=subnet-0314bda17e8a25f08"

# 檢查安全群組規則
aws ec2 describe-security-groups --region ap-southeast-1 \
  --group-ids <security-group-id>
```

### 方案 2：更新 EC2NodeClass UserData
```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  userData: |
    #!/bin/bash
    set -e
    
    # 獲取集群信息
    CLUSTER_NAME="eks-lab-test-eks"
    B64_CLUSTER_CA=$(aws eks describe-cluster \
      --name $CLUSTER_NAME \
      --query "cluster.certificateAuthority.data" \
      --output text)
    API_SERVER_URL=$(aws eks describe-cluster \
      --name $CLUSTER_NAME \
      --query "cluster.endpoint" \
      --output text)
    
    # Bootstrap
    /etc/eks/bootstrap.sh $CLUSTER_NAME \
      --b64-cluster-ca $B64_CLUSTER_CA \
      --apiserver-endpoint $API_SERVER_URL \
      --dns-cluster-ip 10.100.0.10
```

### 方案 3：手動調試
1. 獲取實例 ID：
```bash
kubectl get nodeclaim <name> -o jsonpath='{.status.providerID}'
```

2. 使用 Session Manager 連接：
```bash
aws ssm start-session --target <instance-id>
```

3. 檢查日誌：
```bash
sudo cat /var/log/cloud-init-output.log
sudo journalctl -u kubelet -f
```

### 方案 4：使用 Managed Node Groups（替代方案）
如果 Karpenter 節點持續無法加入，可以考慮使用 EKS Managed Node Groups：

```bash
eksctl create nodegroup \
  --cluster eks-lab-test-eks \
  --name managed-ng \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 5 \
  --managed
```

## 測試腳本
使用修復的測試腳本：
```bash
./scripts/test-karpenter-fixed.sh
```

## 監控命令
```bash
# 監控 NodeClaim
kubectl get nodeclaims -A -w

# 監控 Karpenter 日誌
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f

# 檢查 EC2 實例
aws ec2 describe-instances --region ap-southeast-1 \
  --filters "Name=tag:karpenter.sh/nodepool,Values=general-purpose"
```

## 後續步驟

1. **短期解決**：
   - 使用 Managed Node Groups 進行測試
   - 手動調試一個 Karpenter 創建的實例

2. **長期解決**：
   - 修復 UserData 腳本
   - 確保網絡配置正確
   - 考慮升級到最新的 Karpenter 版本

## 參考資源
- [Karpenter Troubleshooting](https://karpenter.sh/docs/troubleshooting/)
- [EKS Node Joining Issues](https://aws.amazon.com/premiumsupport/knowledge-center/eks-worker-nodes-cluster/)
- [Karpenter GitHub Issues](https://github.com/aws/karpenter-provider-aws/issues)

---
**報告日期**: 2025-08-25
**作者**: jasontsai
**狀態**: 🔧 需要進一步調試