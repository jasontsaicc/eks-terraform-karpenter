#!/bin/bash

# Terraform Backend 設定腳本
# 此腳本會建立 S3 bucket 和 DynamoDB 表用於 Terraform 狀態管理

set -e

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 函數定義
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 檢查必要工具
check_prerequisites() {
    log_step "檢查必要工具..."
    
    # 檢查 Terraform
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform 未安裝"
        exit 1
    fi
    
    # 檢查 AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI 未安裝"
        exit 1
    fi
    
    # 檢查 AWS 認證
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS 認證失敗，請設定 AWS credentials"
        exit 1
    fi
    
    log_info "所有必要工具已就緒"
}

# 顯示當前 AWS 帳戶資訊
show_aws_info() {
    log_step "顯示 AWS 帳戶資訊..."
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local user_arn=$(aws sts get-caller-identity --query Arn --output text)
    local region=$(aws configure get region || echo "未設定")
    
    echo "================================================"
    echo "AWS 帳戶 ID: $account_id"
    echo "使用者/角色: $user_arn"
    echo "預設區域: $region"
    echo "================================================"
}

# 建立 Terraform backend 基礎設施
create_backend() {
    log_step "建立 Terraform backend 基礎設施..."
    
    # 進入 backend 目錄
    cd terraform-backend
    
    # 初始化 Terraform
    log_info "初始化 Terraform..."
    terraform init
    
    # 驗證配置
    log_info "驗證 Terraform 配置..."
    terraform validate
    
    # 規劃部署
    log_info "規劃 backend 部署..."
    terraform plan -out=backend.tfplan
    
    # 詢問確認
    echo ""
    log_warn "即將建立以下 AWS 資源："
    echo "  - S3 bucket (Terraform 狀態儲存)"
    echo "  - DynamoDB 表 (狀態鎖定)"
    echo "  - 相關的 IAM 政策和加密設定"
    echo ""
    read -p "確定要繼續嗎？ (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "部署已取消"
        rm -f backend.tfplan
        exit 0
    fi
    
    # 執行部署
    log_info "開始部署 backend 基礎設施..."
    terraform apply backend.tfplan
    
    # 清理計劃檔案
    rm -f backend.tfplan
    
    # 回到主目錄
    cd ..
}

# 獲取 backend 配置資訊
get_backend_config() {
    log_step "獲取 backend 配置資訊..."
    
    cd terraform-backend
    
    # 獲取輸出值
    local bucket_name=$(terraform output -raw s3_bucket_name)
    local dynamodb_table=$(terraform output -raw dynamodb_table_name)
    local region=$(terraform output -raw s3_bucket_region)
    
    # 儲存配置到檔案
    cat > ../backend-config.txt << EOF
# Terraform Backend 配置資訊
# 請將以下配置複製到主要的 main.tf 檔案中

terraform {
  backend "s3" {
    bucket         = "$bucket_name"
    key            = "eks/terraform.tfstate"
    region         = "$region"
    dynamodb_table = "$dynamodb_table"
    encrypt        = true
  }
}

# AWS CLI 命令驗證資源
aws s3 ls s3://$bucket_name
aws dynamodb describe-table --table-name $dynamodb_table --region $region
EOF
    
    cd ..
    
    echo ""
    log_info "Backend 配置已儲存到 backend-config.txt"
    echo ""
    echo "================================================"
    echo "🎉 Terraform Backend 建立成功！"
    echo ""
    echo "📦 S3 Bucket: $bucket_name"
    echo "🔒 DynamoDB 表: $dynamodb_table"
    echo "🌏 區域: $region"
    echo ""
    echo "📝 下一步："
    echo "1. 檢查 backend-config.txt 檔案"
    echo "2. 將 backend 配置複製到主要的 main.tf"
    echo "3. 執行 'terraform init' 遷移狀態"
    echo "================================================"
}

# 更新主要 Terraform 配置
update_main_config() {
    log_step "更新主要 Terraform 配置..."
    
    if [ ! -f "terraform-backend/terraform.tfstate" ]; then
        log_error "Backend 尚未建立，請先執行 backend 建立流程"
        return 1
    fi
    
    cd terraform-backend
    local bucket_name=$(terraform output -raw s3_bucket_name)
    local dynamodb_table=$(terraform output -raw dynamodb_table_name)
    local region=$(terraform output -raw s3_bucket_region)
    cd ..
    
    # 備份原始檔案
    cp main.tf main.tf.backup
    
    # 更新 backend 配置
    cat > temp_backend.tf << EOF
terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }

  backend "s3" {
    bucket         = "$bucket_name"
    key            = "eks/terraform.tfstate"
    region         = "$region"
    dynamodb_table = "$dynamodb_table"
    encrypt        = true
  }
}
EOF

    # 替換 main.tf 中的 terraform 區塊
    sed -i '/^terraform {/,/^}/d' main.tf
    cat temp_backend.tf main.tf > main.tf.new && mv main.tf.new main.tf
    rm temp_backend.tf
    
    log_info "主要 Terraform 配置已更新"
}

# 驗證 backend 資源
verify_backend() {
    log_step "驗證 backend 資源..."
    
    cd terraform-backend
    local bucket_name=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")
    local dynamodb_table=$(terraform output -raw dynamodb_table_name 2>/dev/null || echo "")
    local region=$(terraform output -raw s3_bucket_region 2>/dev/null || echo "ap-east-2")
    cd ..
    
    if [ -z "$bucket_name" ] || [ -z "$dynamodb_table" ]; then
        log_error "無法獲取 backend 配置資訊"
        return 1
    fi
    
    # 檢查 S3 bucket
    if aws s3api head-bucket --bucket "$bucket_name" --region "$region" 2>/dev/null; then
        log_info "✓ S3 bucket '$bucket_name' 存在且可存取"
    else
        log_error "✗ S3 bucket '$bucket_name' 不存在或無法存取"
        return 1
    fi
    
    # 檢查 DynamoDB 表
    if aws dynamodb describe-table --table-name "$dynamodb_table" --region "$region" >/dev/null 2>&1; then
        log_info "✓ DynamoDB 表 '$dynamodb_table' 存在且可存取"
    else
        log_error "✗ DynamoDB 表 '$dynamodb_table' 不存在或無法存取"
        return 1
    fi
    
    log_info "Backend 驗證成功！"
}

# 清理 backend 資源
cleanup_backend() {
    log_step "清理 Terraform backend 資源..."
    
    log_warn "⚠️  警告：此操作將刪除所有 backend 資源，包括儲存的 Terraform 狀態！"
    read -p "確定要清理 backend 資源嗎？ (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "清理已取消"
        return 0
    fi
    
    cd terraform-backend
    
    # 檢查是否存在狀態檔案
    if [ -f "terraform.tfstate" ]; then
        log_info "開始清理 backend 資源..."
        terraform destroy -auto-approve
        log_info "Backend 資源已清理完成"
    else
        log_warn "未找到 Terraform 狀態檔案"
    fi
    
    cd ..
    
    # 清理設定檔案
    rm -f backend-config.txt
    rm -f main.tf.backup
    
    log_info "清理完成"
}

# 顯示使用說明
show_usage() {
    echo "Terraform Backend 設定腳本"
    echo ""
    echo "用法: $0 [選項]"
    echo ""
    echo "選項:"
    echo "  create      建立 S3 bucket 和 DynamoDB 表"
    echo "  update      更新主要 Terraform 配置使用 backend"
    echo "  verify      驗證 backend 資源是否正常"
    echo "  cleanup     清理所有 backend 資源"
    echo "  info        顯示當前 AWS 帳戶資訊"
    echo "  help        顯示此說明"
    echo ""
    echo "範例:"
    echo "  $0 create   # 建立 backend 資源"
    echo "  $0 verify   # 驗證 backend 資源"
    echo "  $0 cleanup  # 清理 backend 資源"
}

# 主程序
main() {
    case "${1:-}" in
        create)
            check_prerequisites
            show_aws_info
            create_backend
            get_backend_config
            ;;
        update)
            check_prerequisites
            update_main_config
            ;;
        verify)
            check_prerequisites
            verify_backend
            ;;
        cleanup)
            check_prerequisites
            cleanup_backend
            ;;
        info)
            check_prerequisites
            show_aws_info
            ;;
        help|--help|-h)
            show_usage
            ;;
        "")
            log_info "開始完整的 backend 設定流程..."
            check_prerequisites
            show_aws_info
            create_backend
            get_backend_config
            update_main_config
            log_info "Backend 設定完成！現在可以執行主要的 Terraform 部署"
            ;;
        *)
            log_error "未知選項: $1"
            show_usage
            exit 1
            ;;
    esac
}

# 執行主程序
main "$@"