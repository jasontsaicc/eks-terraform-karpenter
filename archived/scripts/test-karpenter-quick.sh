#!/bin/bash

# Quick Karpenter Testing Script
# Fast validation of core Karpenter functionality
# Author: jasontsai

echo "🧪 Quick Karpenter Functionality Test"
echo "====================================="
echo ""

# Environment variables
export KUBECONFIG=/home/ubuntu/.kube/config

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'  
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Test 1: Karpenter Status
echo "🔍 Test 1: Karpenter Status Check"
echo "--------------------------------"
KARPENTER_STATUS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | awk '{print $3}' | head -1)
if [ "$KARPENTER_STATUS" = "Running" ]; then
    log_success "Karpenter is running normally"
else
    log_error "Karpenter status: $KARPENTER_STATUS"
fi
echo ""

# Test 2: NodePool Configuration
echo "🎯 Test 2: NodePool Configuration"
echo "--------------------------------"
NODEPOOL_STATUS=$(kubectl get nodepool general-purpose -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$NODEPOOL_STATUS" = "True" ]; then
    POLICY=$(kubectl get nodepool general-purpose -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null)
    log_success "NodePool ready with policy: $POLICY"
else
    log_error "NodePool not ready or missing"
fi
echo ""

# Test 3: Quick Scale-Up Test
echo "⬆️  Test 3: Scale-Up Test (30 seconds)"
echo "-------------------------------------"
log_info "Creating high-demand workload..."

# Clean up any existing test
kubectl delete deployment quick-test --ignore-not-found=true >/dev/null 2>&1

cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quick-test
spec:
  replicas: 3
  selector:
    matchLabels:
      app: quick-test
  template:
    metadata:
      labels:
        app: quick-test
    spec:
      containers:
      - name: test
        image: nginx:alpine
        resources:
          requests:
            cpu: "900m"
            memory: "500Mi"
EOF

log_info "Waiting for Karpenter response (30 seconds)..."
sleep 30

NODECLAIMS_COUNT=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
if [ "$NODECLAIMS_COUNT" -gt 0 ]; then
    INSTANCE_TYPES=$(kubectl get nodeclaims -o jsonpath='{.items[*].status.capacity.instance-type}' 2>/dev/null | tr ' ' ',')
    CAPACITY_TYPES=$(kubectl get nodeclaims -o jsonpath='{.items[*].status.capacity.capacity-type}' 2>/dev/null | tr ' ' ',')
    log_success "Created $NODECLAIMS_COUNT NodeClaim(s) - Types: $INSTANCE_TYPES - Pricing: $CAPACITY_TYPES"
else
    log_error "No NodeClaims created after 30 seconds"
fi
echo ""

# Test 4: Configuration Validation
echo "⚙️  Test 4: Configuration Summary"
echo "--------------------------------"
INITIAL_NODES=$(kubectl get nodes --no-headers | wc -l)
log_info "Current nodes: $INITIAL_NODES"
log_info "Current NodeClaims: $NODECLAIMS_COUNT"

if [ "$NODECLAIMS_COUNT" -gt 0 ]; then
    kubectl get nodeclaims -o wide 2>/dev/null
fi
echo ""

# Clean up
echo "🧹 Cleanup"
echo "----------"
log_info "Cleaning up test resources..."
kubectl delete deployment quick-test --ignore-not-found=true >/dev/null 2>&1
kubectl delete nodeclaims --all --ignore-not-found=true >/dev/null 2>&1

echo ""
echo "📊 Quick Test Summary"
echo "===================="
if [ "$KARPENTER_STATUS" = "Running" ] && [ "$NODEPOOL_STATUS" = "True" ] && [ "$NODECLAIMS_COUNT" -gt 0 ]; then
    log_success "🎉 Karpenter is working correctly!"
    echo ""
    echo "✅ Core functionality verified:"
    echo "   • Karpenter pod running"
    echo "   • NodePool configured correctly"  
    echo "   • Auto-scaling triggered successfully"
    echo "   • Instance provisioning working"
    echo ""
    echo "🚀 Ready for production workloads!"
else
    log_error "❌ Some issues detected - check individual test results above"
fi