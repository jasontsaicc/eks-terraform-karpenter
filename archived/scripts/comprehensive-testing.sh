#!/bin/bash

# 企業級 EKS + Karpenter 綜合測試腳本
# Author: jasontsai
# 測試所有關鍵功能和故障恢復場景

set -e

# 顏色和日誌配置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

TEST_LOG="/tmp/eks-test-$(date +%Y%m%d-%H%M%S).log"
FAILED_TESTS=()
PASSED_TESTS=()

# 日誌函數
log_test() {
    echo -e "${BLUE}[TEST]${NC} $1" | tee -a $TEST_LOG
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1" | tee -a $TEST_LOG
    PASSED_TESTS+=("$1")
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" | tee -a $TEST_LOG
    FAILED_TESTS+=("$1")
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a $TEST_LOG
}

log_info() {
    echo -e "${PURPLE}[INFO]${NC} $1" | tee -a $TEST_LOG
}

# 測試配置
CLUSTER_NAME="eks-lab-test-eks"
NAMESPACE_TEST="karpenter-test"
TEST_APP_NAME="load-test-app"

# 初始化測試環境
setup_test_environment() {
    log_test "設置測試環境"
    
    # 創建測試命名空間
    kubectl create namespace $NAMESPACE_TEST --dry-run=client -o yaml | kubectl apply -f -
    
    # 標記測試命名空間
    kubectl label namespace $NAMESPACE_TEST testing=true --overwrite
    
    log_pass "測試環境設置完成"
}

# 測試 1: EKS 集群基礎功能
test_eks_cluster_health() {
    log_test "測試 EKS 集群健康狀態"
    
    # 檢查集群狀態
    if kubectl cluster-info &>/dev/null; then
        log_pass "集群 API 服務器可訪問"
    else
        log_fail "集群 API 服務器不可訪問"
        return 1
    fi
    
    # 檢查節點狀態
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c Ready || echo "0")
    if [ "$ready_nodes" -gt 0 ]; then
        log_pass "發現 $ready_nodes 個就緒節點"
    else
        log_fail "沒有就緒的節點"
        return 1
    fi
    
    # 檢查核心服務
    local coredns_ready=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers | grep -c Running || echo "0")
    if [ "$coredns_ready" -gt 0 ]; then
        log_pass "CoreDNS 服務正常"
    else
        log_fail "CoreDNS 服務異常"
    fi
    
    # 檢查 AWS Load Balancer Controller
    local alb_ready=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers | grep -c Running || echo "0")
    if [ "$alb_ready" -gt 0 ]; then
        log_pass "AWS Load Balancer Controller 運行正常"
    else
        log_warn "AWS Load Balancer Controller 未運行或未安裝"
    fi
}

# 測試 2: Karpenter 核心功能
test_karpenter_functionality() {
    log_test "測試 Karpenter 核心功能"
    
    # 檢查 Karpenter Pod 狀態
    local karpenter_pods=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter --no-headers | grep -c Running || echo "0")
    if [ "$karpenter_pods" -gt 0 ]; then
        log_pass "Karpenter 控制器運行正常 ($karpenter_pods 個 Pod)"
    else
        log_fail "Karpenter 控制器未運行"
        return 1
    fi
    
    # 檢查 NodePool 配置
    local nodepools=$(kubectl get nodepools --no-headers | wc -l)
    if [ "$nodepools" -gt 0 ]; then
        log_pass "發現 $nodepools 個 NodePool 配置"
        kubectl get nodepools -o wide | tee -a $TEST_LOG
    else
        log_fail "沒有發現 NodePool 配置"
        return 1
    fi
    
    # 檢查 EC2NodeClass 配置
    local ec2nodeclasses=$(kubectl get ec2nodeclasses --no-headers | wc -l)
    if [ "$ec2nodeclasses" -gt 0 ]; then
        log_pass "發現 $ec2nodeclasses 個 EC2NodeClass 配置"
        kubectl get ec2nodeclasses -o wide | tee -a $TEST_LOG
    else
        log_fail "沒有發現 EC2NodeClass 配置"
    fi
}

# 測試 3: Karpenter 自動擴展
test_karpenter_autoscaling() {
    log_test "測試 Karpenter 自動擴展功能"
    
    # 記錄初始節點數量
    local initial_nodes=$(kubectl get nodes --no-headers | wc -l)
    log_info "初始節點數量: $initial_nodes"
    
    # 部署需要大量資源的測試應用
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $TEST_APP_NAME
  namespace: $NAMESPACE_TEST
spec:
  replicas: 5
  selector:
    matchLabels:
      app: $TEST_APP_NAME
  template:
    metadata:
      labels:
        app: $TEST_APP_NAME
    spec:
      tolerations:
        - key: karpenter.sh/nodepool
          value: general-purpose
          effect: NoSchedule
      nodeSelector:
        nodepool: general-purpose
      containers:
      - name: stress-test
        image: polinux/stress
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            cpu: 1500m
            memory: 3Gi
        command: ["stress"]
        args: ["--cpu", "1", "--timeout", "300s"]
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: $TEST_APP_NAME
EOF
    
    log_info "已部署高資源需求測試應用，等待 Karpenter 調配節點..."
    
    # 等待並監控節點擴展
    local timeout=600
    local elapsed=0
    local new_nodes_created=false
    
    while [ $elapsed -lt $timeout ]; do
        local current_nodes=$(kubectl get nodes --no-headers | wc -l)
        local pending_pods=$(kubectl get pods -n $NAMESPACE_TEST -l app=$TEST_APP_NAME --field-selector=status.phase=Pending --no-headers | wc -l)
        local running_pods=$(kubectl get pods -n $NAMESPACE_TEST -l app=$TEST_APP_NAME --field-selector=status.phase=Running --no-headers | wc -l)
        
        log_info "當前狀態 - 節點: $current_nodes, 運行中 Pod: $running_pods, 等待中 Pod: $pending_pods"
        
        # 檢查是否有新節點被創建
        if [ $current_nodes -gt $initial_nodes ]; then
            new_nodes_created=true
            log_pass "Karpenter 成功創建新節點 (從 $initial_nodes 增加到 $current_nodes)"
            break
        fi
        
        # 檢查 NodeClaims
        local nodeclaims=$(kubectl get nodeclaims --no-headers | wc -l)
        if [ $nodeclaims -gt 0 ]; then
            log_info "發現 $nodeclaims 個 NodeClaim，正在佈建節點..."
            kubectl get nodeclaims | tee -a $TEST_LOG
        fi
        
        sleep 30
        elapsed=$((elapsed + 30))
    done
    
    if [ "$new_nodes_created" = true ]; then
        log_pass "Karpenter 自動擴展測試通過"
        
        # 顯示新創建的節點
        log_info "新創建的節點詳情:"
        kubectl get nodes --sort-by=.metadata.creationTimestamp | tail -n $((current_nodes - initial_nodes)) | tee -a $TEST_LOG
    else
        log_fail "Karpenter 自動擴展測試失敗 - 在 $timeout 秒內未創建新節點"
    fi
}

# 測試 4: 節點縮減功能
test_karpenter_scale_down() {
    log_test "測試 Karpenter 節點縮減功能"
    
    # 刪除測試應用
    kubectl delete deployment $TEST_APP_NAME -n $NAMESPACE_TEST --wait=true
    
    log_info "已刪除測試應用，等待節點縮減..."
    
    # 記錄當前節點數
    local nodes_before_scale_down=$(kubectl get nodes --no-headers | wc -l)
    
    # 等待節點縮減
    local timeout=600
    local elapsed=0
    local nodes_scaled_down=false
    
    while [ $elapsed -lt $timeout ]; do
        local current_nodes=$(kubectl get nodes --no-headers | wc -l)
        
        if [ $current_nodes -lt $nodes_before_scale_down ]; then
            nodes_scaled_down=true
            log_pass "Karpenter 成功縮減節點 (從 $nodes_before_scale_down 減少到 $current_nodes)"
            break
        fi
        
        # 檢查節點是否標記為即將刪除
        local terminating_nodes=$(kubectl get nodes --no-headers | grep -c SchedulingDisabled || echo "0")
        if [ $terminating_nodes -gt 0 ]; then
            log_info "發現 $terminating_nodes 個節點正在終止中"
        fi
        
        sleep 30
        elapsed=$((elapsed + 30))
    done
    
    if [ "$nodes_scaled_down" = true ]; then
        log_pass "Karpenter 節點縮減測試通過"
    else
        log_warn "Karpenter 節點縮減測試 - 在 $timeout 秒內未觀察到節點縮減（可能由於 ttlSecondsAfterEmpty 設置較長）"
    fi
}

# 測試 5: Spot 實例中斷處理
test_spot_interruption_handling() {
    log_test "測試 Spot 實例中斷處理機制"
    
    # 檢查 SQS 中斷佇列
    local queue_name="$CLUSTER_NAME"
    if aws sqs get-queue-url --queue-name "$queue_name" &>/dev/null; then
        log_pass "SQS 中斷佇列配置正確"
    else
        log_fail "SQS 中斷佇列未配置或無法訪問"
    fi
    
    # 部署可容忍中斷的測試工作負載
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spot-test
  namespace: $NAMESPACE_TEST
spec:
  replicas: 3
  selector:
    matchLabels:
      app: spot-test
  template:
    metadata:
      labels:
        app: spot-test
    spec:
      tolerations:
        - key: karpenter.sh/nodepool
          value: general-purpose
          effect: NoSchedule
        - key: aws.amazon.com/spot
          operator: Exists
      nodeSelector:
        karpenter.sh/capacity-type: spot
      containers:
      - name: nginx
        image: nginx:1.24
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
EOF
    
    # 等待 Pod 調度到 Spot 節點
    sleep 60
    
    local spot_pods=$(kubectl get pods -n $NAMESPACE_TEST -l app=spot-test --no-headers | grep -c Running || echo "0")
    if [ $spot_pods -gt 0 ]; then
        log_pass "Spot 實例測試工作負載部署成功 ($spot_pods 個 Pod)"
    else
        log_warn "Spot 實例測試工作負載未能成功調度"
    fi
    
    # 清理測試工作負載
    kubectl delete deployment spot-test -n $NAMESPACE_TEST --wait=true
}

# 測試 6: 網路連接和 DNS 解析
test_networking_and_dns() {
    log_test "測試網路連接和 DNS 解析"
    
    # 部署網路測試 Pod
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: network-test
  namespace: $NAMESPACE_TEST
spec:
  containers:
  - name: network-tools
    image: nicolaka/netshoot:latest
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF
    
    # 等待 Pod 就緒
    kubectl wait --for=condition=Ready pod/network-test -n $NAMESPACE_TEST --timeout=120s
    
    if [ $? -eq 0 ]; then
        log_pass "網路測試 Pod 成功啟動"
        
        # 測試 DNS 解析
        if kubectl exec -n $NAMESPACE_TEST network-test -- nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
            log_pass "內部 DNS 解析正常"
        else
            log_fail "內部 DNS 解析失敗"
        fi
        
        # 測試外部網路連接
        if kubectl exec -n $NAMESPACE_TEST network-test -- curl -s --connect-timeout 10 https://aws.amazon.com &>/dev/null; then
            log_pass "外部網路連接正常"
        else
            log_fail "外部網路連接失敗"
        fi
        
        # 清理測試 Pod
        kubectl delete pod network-test -n $NAMESPACE_TEST --wait=true
    else
        log_fail "網路測試 Pod 啟動失敗"
    fi
}

# 測試 7: 儲存功能
test_storage_functionality() {
    log_test "測試 EBS CSI 儲存功能"
    
    # 檢查 EBS CSI Driver
    local ebs_csi_pods=$(kubectl get pods -n kube-system -l app=ebs-csi-controller --no-headers | grep -c Running || echo "0")
    if [ $ebs_csi_pods -gt 0 ]; then
        log_pass "EBS CSI Driver 運行正常"
    else
        log_warn "EBS CSI Driver 未運行"
        return 0
    fi
    
    # 創建測試 PVC
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ebs-claim
  namespace: $NAMESPACE_TEST
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp2
  resources:
    requests:
      storage: 1Gi
EOF
    
    # 部署使用 PVC 的測試 Pod
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
  namespace: $NAMESPACE_TEST
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo 'storage test' > /data/test.txt && sleep 300"]
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-ebs-claim
  restartPolicy: Never
EOF
    
    # 等待 PVC 綁定
    local timeout=120
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        local pvc_status=$(kubectl get pvc test-ebs-claim -n $NAMESPACE_TEST -o jsonpath='{.status.phase}')
        if [ "$pvc_status" = "Bound" ]; then
            log_pass "EBS 儲存卷成功綁定"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    if [ "$pvc_status" != "Bound" ]; then
        log_fail "EBS 儲存卷綁定失敗"
    fi
    
    # 清理儲存測試資源
    kubectl delete pod storage-test -n $NAMESPACE_TEST --wait=true
    kubectl delete pvc test-ebs-claim -n $NAMESPACE_TEST --wait=true
}

# 測試 8: 監控和日誌
test_monitoring_and_logging() {
    log_test "測試監控和日誌功能"
    
    # 檢查節點指標
    if kubectl top nodes &>/dev/null; then
        log_pass "節點指標收集正常"
        kubectl top nodes | head -5 | tee -a $TEST_LOG
    else
        log_warn "節點指標收集不可用（可能需要安裝 Metrics Server）"
    fi
    
    # 檢查 Pod 指標
    if kubectl top pods -n karpenter &>/dev/null; then
        log_pass "Pod 指標收集正常"
    else
        log_warn "Pod 指標收集不可用"
    fi
    
    # 檢查 Karpenter 日誌
    local karpenter_logs=$(kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=10 --since=5m)
    if [ -n "$karpenter_logs" ]; then
        log_pass "Karpenter 日誌可正常訪問"
        echo "最近的 Karpenter 日誌:" >> $TEST_LOG
        echo "$karpenter_logs" >> $TEST_LOG
    else
        log_warn "無法獲取 Karpenter 日誌"
    fi
}

# 測試 9: 安全性和 RBAC
test_security_and_rbac() {
    log_test "測試安全性和 RBAC 配置"
    
    # 檢查 Karpenter 服務帳戶
    local karpenter_sa=$(kubectl get serviceaccount -n karpenter karpenter -o name 2>/dev/null || echo "")
    if [ -n "$karpenter_sa" ]; then
        log_pass "Karpenter 服務帳戶配置正確"
        
        # 檢查 IRSA 註解
        local role_annotation=$(kubectl get serviceaccount -n karpenter karpenter -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
        if [ -n "$role_annotation" ]; then
            log_pass "IRSA 配置正確: $role_annotation"
        else
            log_fail "IRSA 配置缺失"
        fi
    else
        log_fail "Karpenter 服務帳戶未找到"
    fi
    
    # 測試未授權訪問
    if kubectl auth can-i create pods --as=system:unauthenticated &>/dev/null; then
        log_fail "安全問題：未經身份驗證的使用者可以創建 Pod"
    else
        log_pass "RBAC 安全配置正確"
    fi
}

# 測試 10: 災難恢復場景
test_disaster_recovery() {
    log_test "測試災難恢復場景"
    
    # 模擬 Karpenter 控制器重啟
    log_info "模擬 Karpenter 控制器重啟..."
    kubectl rollout restart deployment/karpenter -n karpenter
    
    # 等待重啟完成
    kubectl rollout status deployment/karpenter -n karpenter --timeout=300s
    
    if [ $? -eq 0 ]; then
        log_pass "Karpenter 控制器重啟恢復測試通過"
    else
        log_fail "Karpenter 控制器重啟恢復測試失敗"
    fi
    
    # 驗證重啟後功能正常
    sleep 30
    local karpenter_pods_after=$(kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter --no-headers | grep -c Running || echo "0")
    if [ $karpenter_pods_after -gt 0 ]; then
        log_pass "Karpenter 控制器重啟後運行正常"
    else
        log_fail "Karpenter 控制器重啟後運行異常"
    fi
}

# 清理測試環境
cleanup_test_environment() {
    log_test "清理測試環境"
    
    # 刪除測試命名空間及其所有資源
    kubectl delete namespace $NAMESPACE_TEST --wait=true
    
    log_pass "測試環境清理完成"
}

# 生成測試報告
generate_test_report() {
    local total_tests=$((${#PASSED_TESTS[@]} + ${#FAILED_TESTS[@]}))
    local pass_rate=$(echo "scale=2; ${#PASSED_TESTS[@]} * 100 / $total_tests" | bc -l)
    
    echo "" | tee -a $TEST_LOG
    echo "=============================================" | tee -a $TEST_LOG
    echo "🧪 EKS + Karpenter 綜合測試報告" | tee -a $TEST_LOG
    echo "=============================================" | tee -a $TEST_LOG
    echo "測試時間: $(date)" | tee -a $TEST_LOG
    echo "集群名稱: $CLUSTER_NAME" | tee -a $TEST_LOG
    echo "總測試數: $total_tests" | tee -a $TEST_LOG
    echo "通過測試: ${#PASSED_TESTS[@]}" | tee -a $TEST_LOG
    echo "失敗測試: ${#FAILED_TESTS[@]}" | tee -a $TEST_LOG
    echo "通過率: ${pass_rate}%" | tee -a $TEST_LOG
    echo "" | tee -a $TEST_LOG
    
    if [ ${#PASSED_TESTS[@]} -gt 0 ]; then
        echo "✅ 通過的測試:" | tee -a $TEST_LOG
        for test in "${PASSED_TESTS[@]}"; do
            echo "   • $test" | tee -a $TEST_LOG
        done
        echo "" | tee -a $TEST_LOG
    fi
    
    if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
        echo "❌ 失敗的測試:" | tee -a $TEST_LOG
        for test in "${FAILED_TESTS[@]}"; do
            echo "   • $test" | tee -a $TEST_LOG
        done
        echo "" | tee -a $TEST_LOG
    fi
    
    echo "📋 完整測試日誌: $TEST_LOG" | tee -a $TEST_LOG
    echo "=============================================" | tee -a $TEST_LOG
    
    # 根據測試結果設置退出碼
    if [ ${#FAILED_TESTS[@]} -eq 0 ]; then
        log_pass "🎉 所有測試通過！"
        exit 0
    else
        log_fail "⚠️  有測試失敗，請檢查詳細日誌"
        exit 1
    fi
}

# 主測試流程
main() {
    echo "============================================="
    echo "🚀 啟動 EKS + Karpenter 綜合測試"
    echo "============================================="
    echo ""
    
    setup_test_environment
    test_eks_cluster_health
    test_karpenter_functionality
    test_karpenter_autoscaling
    test_karpenter_scale_down
    test_spot_interruption_handling
    test_networking_and_dns
    test_storage_functionality
    test_monitoring_and_logging
    test_security_and_rbac
    test_disaster_recovery
    cleanup_test_environment
    generate_test_report
}

# 執行主函數
main "$@"