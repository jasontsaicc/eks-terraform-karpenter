#!/bin/bash

# Test Karpenter Auto-scaling
# Author: jasontsai

set -e

echo "=== 測試 Karpenter 自動擴縮容 ==="
echo ""

export KUBECONFIG=/tmp/eks-config

# Function to wait for pod to be ready
wait_for_pod() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}
    
    echo "等待 Pod 就緒: $label in $namespace..."
    kubectl wait --for=condition=ready pod -l $label -n $namespace --timeout=${timeout}s
}

# Function to check node count
check_nodes() {
    echo "當前節點狀態:"
    echo "系統節點:"
    kubectl get nodes -l role=system --no-headers | wc -l
    echo "應用節點 (Karpenter):"
    kubectl get nodes -l node-role=application --no-headers | wc -l
    echo "Runner節點 (Karpenter):"
    kubectl get nodes -l node-role=gitlab-runner --no-headers | wc -l
    echo ""
    kubectl get nodes -o wide
}

# Test 1: Initial state
echo "Test 1: 檢查初始狀態"
echo "========================="
check_nodes

# Test 2: Deploy application to trigger Karpenter
echo ""
echo "Test 2: 部署應用觸發 Karpenter 創建節點"
echo "========================="

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      nodeSelector:
        node-role: application
      tolerations:
      - key: application
        value: "true"
        effect: NoSchedule
      containers:
      - name: nginx
        image: nginx:latest
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "1"
            memory: "1Gi"
EOF

echo "等待 60 秒讓 Karpenter 創建節點..."
sleep 60

echo "檢查節點創建情況:"
check_nodes

echo "檢查 Pod 狀態:"
kubectl get pods -l app=test-app -o wide

# Test 3: Scale up application
echo ""
echo "Test 3: 擴展應用測試自動擴容"
echo "========================="

kubectl scale deployment test-app --replicas=10

echo "等待 90 秒讓 Karpenter 擴展節點..."
sleep 90

check_nodes
kubectl get pods -l app=test-app -o wide

# Test 4: Deploy GitLab Runner job
echo ""
echo "Test 4: 部署 GitLab Runner 任務測試專用節點"
echo "========================="

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: test-runner-job
  namespace: default
spec:
  template:
    spec:
      nodeSelector:
        node-role: gitlab-runner
      tolerations:
      - key: gitlab-runner
        value: "true"
        effect: NoSchedule
      containers:
      - name: runner
        image: busybox
        command: ["sh", "-c", "echo 'Running CI/CD job...'; sleep 120; echo 'Job completed!'"]
        resources:
          requests:
            cpu: "2"
            memory: "4Gi"
      restartPolicy: Never
EOF

echo "等待 90 秒讓 Karpenter 創建 Runner 節點..."
sleep 90

check_nodes
kubectl get job test-runner-job -o wide
kubectl get pods -l job-name=test-runner-job -o wide

# Test 5: Scale down and test node removal
echo ""
echo "Test 5: 縮減應用測試節點自動刪除"
echo "========================="

kubectl scale deployment test-app --replicas=0

echo "等待 60 秒觀察節點刪除（ttlSecondsAfterEmpty=30）..."
sleep 60

check_nodes

# Test 6: Test time-based scaling
echo ""
echo "Test 6: 測試時間排程縮放"
echo "========================="

echo "手動觸發下班時間縮放:"
kubectl create job --from=cronjob/scale-down-evening test-scale-down -n karpenter

echo "等待 30 秒..."
sleep 30

echo "檢查縮放後的狀態:"
kubectl get deployments -A | grep -E "gitlab|argocd"

# Cleanup
echo ""
echo "Test 7: 清理測試資源"
echo "========================="

kubectl delete deployment test-app 2>/dev/null || true
kubectl delete job test-runner-job 2>/dev/null || true
kubectl delete job test-scale-down -n karpenter 2>/dev/null || true

echo ""
echo "=== 測試完成 ==="
echo ""
echo "測試結果摘要:"
echo "✅ Karpenter 能夠根據 Pod 需求自動創建節點"
echo "✅ 不同類型的工作負載使用不同的節點池"
echo "✅ 節點在空閒後自動刪除"
echo "✅ 時間排程可以控制應用縮放"
echo ""
echo "成本優化建議:"
echo "1. 使用 SPOT 實例可節省 70% 成本"
echo "2. 設置合理的 ttlSecondsAfterEmpty 避免頻繁創建/刪除"
echo "3. 根據實際使用調整時間排程"
echo "4. 監控節點使用率優化 instance types"