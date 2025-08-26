# EKS Terraform 部署錯誤解決手冊

## 目錄
1. [Terraform 循環依賴錯誤](#terraform-循環依賴錯誤)
2. [Terraform State Lock 錯誤](#terraform-state-lock-錯誤)
3. [AWS Route 重複錯誤](#aws-route-重複錯誤)
4. [OIDC Provider 空值錯誤](#oidc-provider-空值錯誤)
5. [VPC Flow Logs 參數錯誤](#vpc-flow-logs-參數錯誤)

---

## Terraform 循環依賴錯誤

### 錯誤訊息
```
Error: Cycle: module.iam.aws_iam_openid_connect_provider.eks, 
module.iam.aws_iam_role.karpenter_controller, 
module.eks.aws_eks_cluster.cluster
```

### 問題原因
- IAM 模組需要 EKS cluster 的 OIDC issuer URL
- EKS 模組需要 IAM 模組的角色 ARN
- 形成循環依賴

### 解決方案

#### 方案1: 分階段部署
```bash
# 第1階段: 部署 VPC
terraform apply -target=module.vpc

# 第2階段: 部署 IAM (使用空的 OIDC URL)
terraform apply -target=module.iam

# 第3階段: 部署 EKS
terraform apply -target=aws_eks_cluster.main

# 第4階段: 更新 IAM 與完整部署
terraform apply
```

#### 方案2: 簡化配置
```hcl
# main.tf - 簡化版本
module "iam" {
  source = "./modules/iam"
  
  cluster_name = local.cluster_name
  cluster_oidc_issuer_url = ""  # 初始為空
  enable_irsa = var.enable_irsa
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = module.iam.cluster_iam_role_arn
  # ... 其他配置
}
```

#### 方案3: 條件資源創建
```hcl
# modules/iam/main.tf
resource "aws_iam_role" "karpenter_controller" {
  count = var.enable_karpenter && var.cluster_oidc_issuer_url != "" ? 1 : 0
  # ... 配置
}

data "tls_certificate" "eks" {
  count = var.cluster_oidc_issuer_url != "" ? 1 : 0
  url = var.cluster_oidc_issuer_url
}
```

---

## Terraform State Lock 錯誤

### 錯誤訊息
```
Error: Error acquiring the state lock
ConditionalCheckFailedException: The conditional request failed
Lock Info:
  ID:        bb8890f2-4d7f-e8a6-695b-08753be51da5
  Path:      eks-lab-terraform-state-58def540/eks/terraform.tfstate
```

### 問題原因
- 上次 Terraform 操作未正常結束
- DynamoDB 中的 lock 未釋放
- 多個 Terraform 進程同時運行

### 解決方案

#### 方案1: 強制解鎖
```bash
# 使用 lock ID 強制解鎖
terraform force-unlock -force bb8890f2-4d7f-e8a6-695b-08753be51da5
```

#### 方案2: 檢查並終止其他進程
```bash
# 檢查是否有其他 terraform 進程
ps aux | grep terraform

# 終止相關進程
kill -9 <PID>
```

#### 方案3: 手動清理 DynamoDB
```bash
# 從 DynamoDB 刪除 lock
aws dynamodb delete-item \
  --table-name eks-lab-terraform-state-lock \
  --key '{"LockID": {"S": "eks-lab-terraform-state-58def540/eks/terraform.tfstate"}}'
```

---

## AWS Route 重複錯誤

### 錯誤訊息
```
Error: api error RouteAlreadyExists: Route in Route Table (rtb-0e3ced8647e882bb2) 
with destination (0.0.0.0/0) already exists
```

### 問題原因
- Route 已經在 AWS 中創建但不在 Terraform state 中
- 重複執行創建操作
- State 不同步

### 解決方案

#### 方案1: 導入現有資源
```bash
# 導入現有 route
terraform import module.vpc.aws_route.private_nat[0] rtb-0e3ced8647e882bb2_0.0.0.0/0
```

#### 方案2: 刷新 State
```bash
# 刷新 terraform state
terraform refresh -var-file="terraform-simple.tfvars"
```

#### 方案3: 檢查並刪除重複資源
```bash
# 檢查現有 routes
aws ec2 describe-route-tables \
  --route-table-ids rtb-0e3ced8647e882bb2 \
  --query 'RouteTables[0].Routes' \
  --region ap-southeast-1

# 如需要，刪除重複的 route
aws ec2 delete-route \
  --route-table-id rtb-0e3ced8647e882bb2 \
  --destination-cidr-block 0.0.0.0/0 \
  --region ap-southeast-1
```

---

## OIDC Provider 空值錯誤

### 錯誤訊息
```
Error: Invalid URL
  with module.iam.data.tls_certificate.eks,
  on modules/iam/main.tf line 101:
  url = var.cluster_oidc_issuer_url
URL "" contains no host

Error: Invalid index
aws_iam_openid_connect_provider.eks is empty tuple
```

### 問題原因
- EKS cluster 尚未創建，OIDC issuer URL 為空
- IAM 模組嘗試使用不存在的 OIDC provider

### 解決方案

#### 方案1: 條件資源創建
```hcl
# modules/iam/main.tf
data "tls_certificate" "eks" {
  count = var.cluster_oidc_issuer_url != "" ? 1 : 0
  url = var.cluster_oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "eks" {
  count = var.enable_irsa && var.cluster_oidc_issuer_url != "" ? 1 : 0
  
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks[0].certificates[0].sha1_fingerprint]
  url             = var.cluster_oidc_issuer_url
}

# 相關角色也需要條件創建
resource "aws_iam_role" "aws_load_balancer_controller" {
  count = var.enable_aws_load_balancer_controller && var.cluster_oidc_issuer_url != "" ? 1 : 0
  # ... 配置
}
```

#### 方案2: 輸出值條件處理
```hcl
# modules/iam/outputs.tf
output "oidc_provider_arn" {
  value = var.enable_irsa && var.cluster_oidc_issuer_url != "" ? 
          aws_iam_openid_connect_provider.eks[0].arn : ""
}

output "karpenter_controller_role_arn" {
  value = var.enable_karpenter && var.cluster_oidc_issuer_url != "" ? 
          aws_iam_role.karpenter_controller[0].arn : ""
}
```

---

## VPC Flow Logs 參數錯誤

### 錯誤訊息
```
Error: Unsupported argument
  on modules/vpc/main.tf line 189:
  189:   log_destination_arn = aws_cloudwatch_log_group.flow_log[0].arn
An argument named "log_destination_arn" is not expected here.
```

### 問題原因
- AWS provider 版本差異
- Flow logs 資源參數名稱變更

### 解決方案

#### 方案1: 更新參數名稱
```hcl
# modules/vpc/main.tf
resource "aws_flow_log" "main" {
  count = var.enable_flow_logs ? 1 : 0

  iam_role_arn         = aws_iam_role.flow_log[0].arn
  log_destination      = aws_cloudwatch_log_group.flow_log[0].arn  # 改用 log_destination
  log_destination_type = "cloud-watch-logs"                        # 指定類型
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.main.id
}
```

#### 方案2: 檢查 Provider 版本
```hcl
# versions.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"  # 確保使用正確版本
    }
  }
}
```

---

## 預防措施

### 1. 部署前檢查清單
```bash
# 檢查 terraform 版本
terraform version

# 驗證配置
terraform validate

# 計劃部署
terraform plan -var-file="terraform-simple.tfvars"

# 檢查 state
terraform state list
```

### 2. 安全部署流程
```bash
# 1. 備份 state
terraform state pull > terraform.tfstate.backup

# 2. 使用 plan 檔案
terraform plan -var-file="terraform-simple.tfvars" -out=eks.tfplan

# 3. 審查 plan
terraform show eks.tfplan

# 4. 應用 plan
terraform apply eks.tfplan
```

### 3. 緊急回滾程序
```bash
# 1. 查看歷史版本
terraform state list

# 2. 回滾到上一版本
terraform state pull > current.tfstate
terraform state push terraform.tfstate.backup

# 3. 或使用 S3 版本控制
aws s3api list-object-versions \
  --bucket eks-lab-terraform-state-58def540 \
  --prefix eks/terraform.tfstate
```

### 4. 監控與日誌
```bash
# 啟用 Terraform 詳細日誌
export TF_LOG=DEBUG
export TF_LOG_PATH=./terraform.log

# 監控部署進度
tail -f terraform.log
```

## 常用診斷命令

```bash
# 檢查 AWS 認證
aws sts get-caller-identity

# 檢查區域設定
echo $AWS_REGION

# 檢查 VPC 資源
aws ec2 describe-vpcs --region ap-southeast-1

# 檢查 EKS 集群
aws eks list-clusters --region ap-southeast-1

# 檢查 IAM 角色
aws iam list-roles | grep eks

# 檢查 Terraform state
terraform state list
terraform state show <resource>

# 檢查 lock 狀態
aws dynamodb scan \
  --table-name eks-lab-terraform-state-lock \
  --region ap-southeast-1
```

## 聯絡資訊

如遇到未列出的錯誤，請：
1. 檢查 [AWS 服務狀態](https://status.aws.amazon.com/)
2. 查看 [Terraform AWS Provider 文檔](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
3. 記錄完整錯誤訊息和執行環境

---

最後更新: 2025-08-24
作者: jasontsai