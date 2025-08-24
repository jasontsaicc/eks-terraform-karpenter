# 🚀 EKS 集群完整部署指南

## ⚠️ 重要注意事項

### 區域設定說明
您最初提到的 `ap-east-2` region **不存在於 AWS**。目前可用的 Asia Pacific regions 包括：

- `ap-east-1` (Asia Pacific Hong Kong) - **目前預設設定**
- `ap-southeast-1` (Asia Pacific Singapore) 
- `ap-southeast-2` (Asia Pacific Sydney)
- `ap-northeast-1` (Asia Pacific Tokyo)
- `ap-northeast-2` (Asia Pacific Seoul)

**行動項目**: 請確認您想使用的正確 region，並相應更新配置檔案。

## 📋 部署前檢查清單

### ✅ 必要準備
- [ ] AWS CLI 已配置且有適當權限
- [ ] 確認使用正確的 AWS region
- [ ] Terraform >= 1.5.0 已安裝
- [ ] kubectl 已安裝
- [ ] 檢查 AWS 帳戶的服務限制

### ✅ 權限確認
確保您的 AWS 使用者/角色具備以下權限：
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "eks:*", 
        "iam:*",
        "cloudwatch:*",
        "logs:*",
        "autoscaling:*",
        "elasticloadbalancing:*"
      ],
      "Resource": "*"
    }
  ]
}
```

## 🔧 詳細部署步驟

### 步驟 1: 環境準備
```bash
# 1. 確認 AWS 配置
aws sts get-caller-identity
aws eks describe-cluster --name non-existent 2>/dev/null || echo "EKS permissions OK"

# 2. 檢查必要工具版本
terraform --version  # >= 1.5.0
kubectl version --client  # >= 1.28
aws --version  # >= 2.0
```

### 步驟 2: 配置自訂設定
```bash
# 1. 複製並編輯環境變數檔案
cp environments/test/terraform.tfvars environments/test/terraform.tfvars.backup
vi environments/test/terraform.tfvars
```

重要配置項目：
```hcl
# 基本設定 - 請根據您的需求修改
project_name = "your-unique-project-name"  # 必須修改
region       = "ap-east-1"                 # 確認正確的 region
azs          = ["ap-east-1a", "ap-east-1b", "ap-east-1c"]  # 對應 region 的 AZ

# 成本優化設定 (建議保持)
node_capacity_type      = "SPOT"      # 使用 Spot 實例節省成本
single_nat_gateway      = true        # 使用單一 NAT Gateway
enable_spot_instances   = true        # 啟用 Spot 實例

# 安全設定 (生產環境請修改)
cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]  # 建議限制為您的 IP
```

### 步驟 3: 驗證配置
```bash
# 1. 初始化 Terraform
terraform init

# 2. 驗證配置檔案
terraform validate

# 3. 檢查計劃（不會實際部署）
terraform plan -var-file=environments/test/terraform.tfvars
```

### 步驟 4: 執行部署
```bash
# 方法一：使用自動化腳本（推薦）
./scripts/deploy.sh

# 方法二：手動步驟
terraform apply -var-file=environments/test/terraform.tfvars -auto-approve
```

**預期部署時間**: 15-20 分鐘

### 步驟 5: 驗證部署
```bash
# 1. 配置 kubectl
CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
aws eks --region $REGION update-kubeconfig --name $CLUSTER_NAME

# 2. 檢查集群狀態
kubectl get nodes
kubectl get pods -A
kubectl cluster-info

# 3. 執行完整驗證
./scripts/validate.sh
```

## 🔧 附加元件安裝指南

### ArgoCD 安裝
```bash
# 1. 安裝 ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. 等待部署完成
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 3. 獲取管理密碼
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# 4. 設定 Port Forward 存取
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
存取：https://localhost:8080，使用者名稱：`admin`

### GitLab Runner 安裝
```bash
# 1. 新增 GitLab Helm Repository
helm repo add gitlab https://charts.gitlab.io
helm repo update

# 2. 建立 namespace
kubectl create namespace gitlab-runner

# 3. 安裝 GitLab Runner
helm install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner \
  --set gitlabUrl=https://your-gitlab-instance.com \
  --set runnerRegistrationToken=your-registration-token \
  --set rbac.create=true
```

### Karpenter 安裝（進階）
```bash
# 1. 更新 Terraform 配置啟用 Karpenter
# 在 main.tf 中設定 enable_karpenter = true

# 2. 重新應用配置
terraform apply -var-file=environments/test/terraform.tfvars

# 3. 安裝 Karpenter
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 0.32.0 \
  --namespace karpenter --create-namespace \
  --set "settings.aws.clusterName=${CLUSTER_NAME}" \
  --set "settings.aws.defaultInstanceProfile=KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --set "settings.aws.interruptionQueueName=${CLUSTER_NAME}" \
  --wait
```

## 💰 成本管理最佳實踐

### 每日成本檢查
```bash
# 1. 檢查 Spot 實例節省情況
aws ec2 describe-spot-instance-requests --region $REGION

# 2. 監控資源使用率
kubectl top nodes
kubectl top pods -A

# 3. 檢查未使用的 LoadBalancer
kubectl get svc -A | grep LoadBalancer
```

### 自動關機設定（節省成本）
```bash
# 建立自動關機腳本（非工作時間）
cat > auto-shutdown.sh << 'EOF'
#!/bin/bash
# 每天 18:00 縮減節點數量到最小
kubectl scale deployment --replicas=0 --all -A
aws autoscaling update-auto-scaling-group --auto-scaling-group-name <your-asg> --desired-capacity 1
EOF

# 使用 cron 或 AWS Lambda 執行
```

## 🚨 故障排除指南

### 常見問題與解決方案

#### 1. Region 不支援錯誤
```
Error: Invalid availability zone: ap-east-2a
```
**解決方案**: 確認使用正確的 AWS region，更新 `terraform.tfvars` 中的 region 和 azs 設定。

#### 2. 權限不足錯誤
```
Error: AccessDenied: User is not authorized to perform: eks:CreateCluster
```
**解決方案**: 檢查 IAM 權限，確保具備 EKS 完整管理權限。

#### 3. Spot 實例中斷
```bash
# 檢查 Spot 實例中斷通知
kubectl describe nodes | grep "spot"
kubectl get events --sort-by='.lastTimestamp' | grep spot
```
**解決方案**: Karpenter 會自動替換中斷的實例，或手動調整實例類型。

#### 4. LoadBalancer 建立失敗
```bash
# 檢查 AWS Load Balancer Controller
kubectl logs -n kube-system deployment/aws-load-balancer-controller
```

### 緊急聯絡與支援
- AWS Support（如有 Support Plan）
- Kubernetes 社群支援
- Terraform 官方文檔

## 🧪 測試場景

### 基本功能測試
```bash
# 1. 部署測試應用
kubectl create deployment test-app --image=nginx
kubectl expose deployment test-app --port=80 --type=LoadBalancer

# 2. 測試自動縮放
kubectl autoscale deployment test-app --cpu-percent=50 --min=1 --max=10

# 3. 測試 Spot 實例容錯
# (模擬 Spot 實例中斷)
```

### GitLab CI/CD 測試
```yaml
# 測試 .gitlab-ci.yml
test-deploy:
  stage: test
  tags:
    - eks-runner
  script:
    - kubectl apply -f k8s/test-deployment.yaml
    - kubectl rollout status deployment/test-app
    - kubectl get pods -l app=test-app
```

## 📊 監控和警報設定

### CloudWatch 儀表板
```bash
# 建立 EKS 監控儀表板
aws cloudwatch put-dashboard --dashboard-name "EKS-Monitoring" --dashboard-body file://dashboard.json
```

### 重要指標警報
- CPU 使用率 > 80%
- Memory 使用率 > 85%
- Spot 實例中斷頻率
- Pod 重啟次數

## 🔄 備份和災難恢復

### 關鍵配置備份
```bash
# 1. 備份 Terraform 狀態
aws s3 cp terraform.tfstate s3://your-backup-bucket/$(date +%Y%m%d)/

# 2. 備份 Kubernetes 配置
kubectl get all --all-namespaces -o yaml > k8s-backup-$(date +%Y%m%d).yaml

# 3. 備份 ETCD（如需要）
kubectl exec -it etcd-pod -n kube-system -- etcdctl snapshot save /backup/etcd-snapshot.db
```

### 恢復程序
1. 重新部署 Terraform 基礎設施
2. 恢復 Kubernetes 配置
3. 重新部署應用程式
4. 驗證服務正常運作

---

**記住**: 這是一個測試環境配置。在生產環境中使用前，請進行充分的安全審查、效能測試和災難恢復計劃。

**成本提醒**: 即使使用 Spot 實例，持續運行仍會產生費用。不使用時請記得清理資源：
```bash
./scripts/destroy.sh
```