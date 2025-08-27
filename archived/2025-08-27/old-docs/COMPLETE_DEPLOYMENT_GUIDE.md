# 🚀 EKS with Karpenter v1.6.2 完整部署指南

## 📋 目標狀態
- **EKS 集群**: v1.30, 2個工作節點 (Amazon Linux 2023)
- **Karpenter**: v1.6.2 (正常運行)
- **AWS Load Balancer Controller**: v2.13.4 (正常運行)
- **VPC**: ap-southeast-1 區域，私有子網路配置
- **成本優化**: Spot 實例優先，自動擴縮容

---

## 🔧 前置需求

### 1. 環境配置
```bash
# 確認 AWS CLI 已配置
aws sts get-caller-identity

# 確認必要工具
which terraform  # >= 1.5.0
which kubectl    # 最新版本  
which helm       # >= 3.0
```

### 2. 設定環境變數
```bash
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export PROJECT_NAME=eks-lab
```

---

## 📁 部署步驟

### Step 1: 準備 Terraform 配置
```bash
cd /home/ubuntu/projects/aws_eks_terraform

# 確認關鍵設定
cat variables.tf | grep -A3 "enable_karpenter\|enable_aws_load_balancer_controller"
```

**關鍵配置確認:**
- `enable_karpenter = true`
- `enable_aws_load_balancer_controller = true` 
- `enable_irsa = true`

### Step 2: 初始化 Terraform Backend
```bash
# 設置 S3 backend (如果尚未存在)
./scripts/setup-backend.sh

# 初始化 Terraform
terraform init
```

### Step 3: 部署基礎設施
```bash
# 檢查計畫
terraform plan

# 部署 (預期時間: 15-20分鐘)
terraform apply -auto-approve
```

### Step 4: 配置 kubectl
```bash
# 更新 kubeconfig
aws eks update-kubeconfig --region ap-southeast-1 --name eks-lab-test-eks

# 如果存在 K3s 集群，需要明確設定
export KUBECONFIG=~/.kube/config

# 驗證連接
kubectl get nodes -o wide
```

**預期結果:**
```
NAME                                           STATUS   ROLES    AGE     VERSION
ip-10-0-10-5.ap-southeast-1.compute.internal   Ready    <none>   5m      v1.30.14-eks-3abbec1
ip-10-0-11-9.ap-southeast-1.compute.internal   Ready    <none>   5m      v1.30.14-eks-3abbec1
```

### Step 5: 安裝 Karpenter v1.6.2
```bash
# 執行完整安裝腳本
./scripts/setup-karpenter-v162.sh
```

**腳本會自動處理:**
- ✅ CRDs 安裝 (v1.6.2)
- ✅ IAM 角色配置
- ✅ Helm 部署配置
- ✅ 區域環境變數設定
- ✅ AWS Load Balancer Controller 修復
- ✅ 資源標記 (subnets, security groups)
- ✅ NodePool 配置

### Step 6: 驗證部署
```bash
# 執行完整測試
./scripts/test-karpenter-comprehensive.sh
```

**預期結果:**
- ✅ Karpenter: 1/1 Running
- ✅ AWS LBC: 2/2 Running  
- ✅ NodePool: 1 Ready
- ✅ EC2NodeClass: 1 Ready

---

## 🔍 關鍵配置檔案

### 1. Karpenter NodePool (v1.6.2)
**檔案:** `karpenter-nodepool-v162.yaml`
```yaml
apiVersion: karpenter.sh/v1  # v1.6.2 API
kind: NodePool
metadata:
  name: general-purpose
  namespace: kube-system      # 正確的命名空間
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          values: ["t3.small", "t3.medium", "t3.large", "m5.large"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
```

### 2. Terraform 配置重點
**檔案:** `variables.tf`
```hcl
variable "enable_karpenter" {
  description = "啟用 Karpenter 自動擴展"
  type        = bool
  default     = true    # 必須為 true
}

variable "enable_aws_load_balancer_controller" {
  description = "啟用 AWS Load Balancer Controller"  
  type        = bool
  default     = true    # 必須為 true
}
```

---

## 🚨 常見問題排解

### 問題 1: Karpenter CrashLoopBackOff
**原因:** 缺少 AWS 區域配置
**解決方案:**
```bash
kubectl patch deployment karpenter -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"controller","env":[{"name":"AWS_REGION","value":"ap-southeast-1"}]}]}}}}'
```

### 問題 2: AWS LBC 初始化失敗
**原因:** 缺少 VPC 配置
**解決方案:**
```bash
VPC_ID=$(aws eks describe-cluster --name eks-lab-test-eks --region ap-southeast-1 --query "cluster.resourcesVpcConfig.vpcId" --output text)

helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set vpcId=$VPC_ID \
  --set region=ap-southeast-1
```

### 問題 3: 無法創建新節點
**原因:** 資源未正確標記
**解決方案:**
```bash
# 標記私有子網路
for subnet in $(aws ec2 describe-subnets --region ap-southeast-1 --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" --query 'Subnets[].SubnetId' --output text); do
  aws ec2 create-tags --region ap-southeast-1 --resources $subnet --tags Key=karpenter.sh/discovery,Value=eks-lab-test-eks
done
```

### 問題 4: kubeconfig 混淆 (K3s vs EKS)
**解決方案:**
```bash
# 臨時禁用 K3s 配置
sudo mv /etc/rancher/k3s/k3s.yaml /etc/rancher/k3s/k3s.yaml.bak

# 使用 EKS 配置
export KUBECONFIG=~/.kube/config
aws eks update-kubeconfig --region ap-southeast-1 --name eks-lab-test-eks
```

---

## 📊 成本估算

### 每日預估成本 (ap-southeast-1)
- **EKS Control Plane**: $0.10/hour = $2.40/day
- **EC2 節點 (2 × t3.medium)**: ~$1.20/day  
- **NAT Gateway**: $1.08/day
- **Load Balancer**: $0.54/day
- **其他服務**: ~$0.50/day

**總計**: ~$5.72/day (~$171.6/month)

### 優化建議
- 使用 Spot 實例可節省 70% EC2 成本
- 啟用 Karpenter 自動縮放減少閒置資源
- 定期清理未使用的 EBS 卷和快照

---

## 🔄 重建流程

### 完整重建 (從清理狀態)
```bash
# 1. 設置環境
export AWS_REGION=ap-southeast-1
cd /home/ubuntu/projects/aws_eks_terraform

# 2. 部署基礎設施  
terraform init
terraform apply -auto-approve

# 3. 配置 kubectl
aws eks update-kubeconfig --region ap-southeast-1 --name eks-lab-test-eks
export KUBECONFIG=~/.kube/config

# 4. 安裝 Karpenter
./scripts/setup-karpenter-v162.sh

# 5. 驗證
./scripts/test-karpenter-comprehensive.sh
```

### 預期完成時間
- **Terraform Apply**: 15-20 分鐘
- **Karpenter 安裝**: 5-10 分鐘  
- **驗證測試**: 5 分鐘
- **總時間**: ~30 分鐘

---

## 🧹 清理指南

### 完整清理 (節省成本)
```bash
# 執行完整清理腳本
./scripts/cleanup-complete.sh

# 或手動清理
terraform destroy -auto-approve
```

**清理項目:**
- ✅ EKS 集群和節點群組
- ✅ VPC、子網路、路由表
- ✅ NAT Gateway、Internet Gateway
- ✅ IAM 角色和政策
- ✅ Load Balancer 和 Target Groups
- ✅ 安全群組
- ✅ CloudWatch 日誌群組

---

## 📝 驗證清單

部署完成後，確認以下項目：

### ✅ 基礎設施
- [ ] EKS 集群狀態為 ACTIVE
- [ ] 2個工作節點正常運行  
- [ ] VPC 和子網路配置正確
- [ ] IAM 角色權限完整

### ✅ 應用程式
- [ ] Karpenter v1.6.2 正常運行 (1/1)
- [ ] AWS LBC v2.13.4 正常運行 (2/2)
- [ ] NodePool 狀態為 Ready
- [ ] EC2NodeClass 狀態為 Ready

### ✅ 功能測試
- [ ] 可以創建新的 Pod
- [ ] Karpenter 能自動配置節點
- [ ] 節點可以正常調度 Pod
- [ ] 成本監控正常工作

---

## 📞 支援資源

- **Karpenter 官方文檔**: https://karpenter.sh/v1.6/
- **AWS EKS 用戶指南**: https://docs.aws.amazon.com/eks/
- **疑難排解腳本**: `./scripts/test-karpenter-comprehensive.sh`
- **日誌查看**: `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter`

---

*最後更新: 2025-08-26*
*版本: v1.6.2-stable*