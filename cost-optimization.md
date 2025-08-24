# EKS 測試環境成本優化策略

## 💰 成本優化措施

### 1. 基礎設施層面優化
- **單一 NAT Gateway**: 使用單一 NAT Gateway 節省 ~$45/月
- **Spot 實例**: 使用 Spot 實例節省 60-90% 計算成本
- **小型實例**: 測試環境使用 t3.medium 而非 m5.large
- **自動關機**: 非工作時間自動關閉環境

### 2. 儲存優化
- **GP3 磁碟**: 使用 GP3 替代 GP2，提供更好的性價比
- **最小磁碟空間**: 節點使用 30GB 而非預設 50GB
- **短期日誌保留**: CloudWatch Logs 保留 7 天

### 3. 網路優化
- **跨 AZ 流量**: 最小化跨可用區流量
- **VPC 端點**: 使用 VPC 端點減少 NAT Gateway 流量
- **關閉 VPC Flow Logs**: 測試環境暫時關閉

### 4. 監控與警報
```bash
# 設定預算警報
aws budgets create-budget --account-id <account-id> --budget '{
  "BudgetName": "EKS-Test-Budget",
  "BudgetLimit": {
    "Amount": "100",
    "Unit": "USD"
  },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": {
    "TagKey": ["Environment"],
    "TagValue": ["test"]
  }
}'
```

## 📊 預估成本（每月）

| 項目 | On-Demand | Spot | 節省 |
|------|-----------|------|------|
| EKS Control Plane | $72 | $72 | $0 |
| t3.medium x 2 | $60 | $18 | $42 |
| NAT Gateway | $45 | $45 | $0 |
| EBS Storage | $6 | $6 | $0 |
| CloudWatch Logs | $3 | $3 | $0 |
| **總計** | **$186** | **$144** | **$42** |

## ⏰ 自動關機腳本

### 工作時間外關機
```bash
# 在 Lambda 中實現
import boto3
import json

def lambda_handler(event, context):
    ec2 = boto3.client('ec2')
    
    # 停止 EKS 節點（通過 Auto Scaling Group）
    asg_client = boto3.client('autoscaling')
    
    # 根據標籤找到 EKS ASG
    response = asg_client.describe_auto_scaling_groups()
    
    for asg in response['AutoScalingGroups']:
        for tag in asg.get('Tags', []):
            if tag['Key'] == 'Environment' and tag['Value'] == 'test':
                # 設定期望容量為 0
                asg_client.update_auto_scaling_group(
                    AutoScalingGroupName=asg['AutoScalingGroupName'],
                    DesiredCapacity=0,
                    MinSize=0
                )
```

### 週末完全關閉
```bash
#!/bin/bash
# weekend-shutdown.sh

# 停止所有 EC2 實例
aws ec2 describe-instances \
    --filters "Name=tag:Environment,Values=test" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text | xargs aws ec2 stop-instances --instance-ids

# 暫停 RDS 實例
aws rds describe-db-instances \
    --query 'DBInstances[?contains(TagList[].Value, `test`)].DBInstanceIdentifier' \
    --output text | xargs -I {} aws rds stop-db-instance --db-instance-identifier {}
```

## 📈 成本監控儀表板

使用 AWS Cost Explorer 或 CloudWatch Dashboard 監控：

1. **日常成本趨勢**
2. **服務別成本分析**
3. **標籤別成本分組**
4. **Spot 實例節省報告**

## 🎯 進一步優化建議

1. **Reserved Instances**: 如果長期使用，考慮購買 RI
2. **Fargate**: 對於批次作業考慮使用 Fargate
3. **Multi-AZ 策略**: 測試環境可考慮單 AZ 部署
4. **CDN**: 使用 CloudFront 降低資料傳輸成本