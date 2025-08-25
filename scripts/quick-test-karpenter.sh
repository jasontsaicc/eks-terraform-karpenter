#!/bin/bash

# Quick Karpenter Test
# Author: jasontsai

echo "=== 快速測試 Karpenter ==="
echo ""

export KUBECONFIG=/tmp/eks-config

# Check current nodes
echo "當前節點:"
kubectl get nodes

echo ""
echo "部署測試應用..."

# Deploy test app
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-test
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: karpenter-test
  template:
    metadata:
      labels:
        app: karpenter-test
    spec:
      nodeSelector:
        node-role: application
      tolerations:
      - key: application
        value: "true"
        effect: NoSchedule
      containers:
      - name: nginx
        image: nginx:alpine
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
EOF

echo ""
echo "等待 Karpenter 創建節點 (約 2-3 分鐘)..."
sleep 30

# Check every 30 seconds
for i in {1..6}; do
    echo "檢查 #$i ($(date +%H:%M:%S)):"
    kubectl get nodes -l node-role=application
    kubectl get pods -l app=karpenter-test -o wide
    echo "---"
    sleep 30
done

echo ""
echo "清理測試資源..."
kubectl delete deployment karpenter-test

echo ""
echo "測試完成！"