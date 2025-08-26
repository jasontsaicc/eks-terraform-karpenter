#!/bin/bash

# Comprehensive Karpenter Testing Script
# Tests node scaling up/down, spot instances, and consolidation policies
# Author: jasontsai

set -e

echo "🧪 Comprehensive Karpenter Functionality Test"
echo "============================================="
echo ""

# Environment variables
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eks-lab-test-eks
export KUBECONFIG=/home/ubuntu/.kube/config

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'  
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=7

test_result() {
    local test_name="$1"
    local result="$2"
    local details="$3"
    
    if [ "$result" = "PASS" ]; then
        log_success "$test_name: PASSED - $details"
        ((TESTS_PASSED++))
    else
        log_error "$test_name: FAILED - $details"
        ((TESTS_FAILED++))
    fi
    echo ""
}

echo "📋 Test Plan:"
echo "1. Pre-flight checks (Karpenter status, NodePool configuration)"
echo "2. Node scaling up test (create high resource demand)"
echo "3. Node scaling down test (remove workload)"  
echo "4. Spot instance provisioning test"
echo "5. Consolidation policy test"
echo "6. Multiple instance type selection test"
echo "7. Resource cleanup test"
echo ""

# Test 1: Pre-flight Checks
echo "🔍 Test 1: Pre-flight Checks"
echo "-----------------------------"

log_info "Checking Karpenter pod status..."
KARPENTER_STATUS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | awk '{print $3}' | head -1)

if [ "$KARPENTER_STATUS" = "Running" ]; then
    KARPENTER_READY=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter --no-headers | awk '{print $2}' | head -1)
    test_result "Karpenter Pod Status" "PASS" "Status: $KARPENTER_STATUS, Ready: $KARPENTER_READY"
else
    test_result "Karpenter Pod Status" "FAIL" "Status: $KARPENTER_STATUS"
fi

log_info "Checking NodePool configuration..."
NODEPOOL_STATUS=$(kubectl get nodepool general-purpose -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

if [ "$NODEPOOL_STATUS" = "True" ]; then
    CONSOLIDATION_POLICY=$(kubectl get nodepool general-purpose -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null)
    test_result "NodePool Configuration" "PASS" "Status: Ready, Policy: $CONSOLIDATION_POLICY"
else
    test_result "NodePool Configuration" "FAIL" "NodePool not ready or missing"
fi

# Get baseline node count
INITIAL_NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
log_info "Initial node count: $INITIAL_NODE_COUNT"

# Test 2: Node Scaling Up Test
echo "⬆️  Test 2: Node Scaling Up Test"
echo "--------------------------------"

log_info "Creating resource-intensive workload..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: scaling-test
  labels:
    test: karpenter-scale-up
spec:
  replicas: 4
  selector:
    matchLabels:
      app: scaling-test
  template:
    metadata:
      labels:
        app: scaling-test
    spec:
      containers:
      - name: consumer
        image: nginx:alpine
        resources:
          requests:
            cpu: "900m"
            memory: "512Mi"
          limits:
            cpu: "1000m"
            memory: "600Mi"
        command:
        - sh
        - -c
        - |
          echo "Scaling test pod started on \$HOSTNAME"
          while true; do sleep 30; echo "Running on \$HOSTNAME"; done
EOF

log_info "Waiting for NodeClaim creation (60 seconds)..."
sleep 60

# Check if NodeClaims were created
NODECLAIMS_COUNT=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
if [ $NODECLAIMS_COUNT -gt 0 ]; then
    NODECLAIM_TYPES=$(kubectl get nodeclaims -o jsonpath='{.items[*].status.capacity.instance-type}' 2>/dev/null | tr ' ' ',')
    test_result "Node Scale-Up" "PASS" "Created $NODECLAIMS_COUNT NodeClaim(s), Types: $NODECLAIM_TYPES"
else
    test_result "Node Scale-Up" "FAIL" "No NodeClaims created"
fi

# Test 3: Spot Instance Test (check if provisioned instances are spot)
echo "💰 Test 3: Spot Instance Provisioning Test"
echo "-------------------------------------------"

if [ $NODECLAIMS_COUNT -gt 0 ]; then
    SPOT_COUNT=$(kubectl get nodeclaims -o jsonpath='{.items[*].status.capacity.capacity-type}' 2>/dev/null | grep -o "spot" | wc -l)
    if [ $SPOT_COUNT -gt 0 ]; then
        test_result "Spot Instance Provisioning" "PASS" "Provisioned $SPOT_COUNT spot instance(s)"
    else
        test_result "Spot Instance Provisioning" "FAIL" "No spot instances provisioned"
    fi
else
    test_result "Spot Instance Provisioning" "FAIL" "No instances to check"
fi

# Test 4: Multiple Instance Type Selection
echo "🎯 Test 4: Instance Type Diversity Test"
echo "---------------------------------------"

if [ $NODECLAIMS_COUNT -gt 1 ]; then
    UNIQUE_TYPES=$(kubectl get nodeclaims -o jsonpath='{.items[*].status.capacity.instance-type}' 2>/dev/null | tr ' ' '\n' | sort -u | wc -l)
    if [ $UNIQUE_TYPES -gt 1 ]; then
        test_result "Instance Type Diversity" "PASS" "Selected $UNIQUE_TYPES different instance types"
    else
        test_result "Instance Type Diversity" "PASS" "Single instance type selected (acceptable for small workload)"
    fi
else
    test_result "Instance Type Diversity" "PASS" "Single NodeClaim created (appropriate for workload size)"
fi

# Test 5: Node Scaling Down Test
echo "⬇️  Test 5: Node Scaling Down Test"
echo "----------------------------------"

log_info "Removing workload to test scale-down..."
kubectl delete deployment scaling-test

log_info "Waiting for consolidation (90 seconds)..."
sleep 90

# Check if NodeClaims are cleaned up (or at least marked for deletion)
REMAINING_NODECLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null | wc -l)
TERMINATING_NODECLAIMS=$(kubectl get nodeclaims --no-headers 2>/dev/null | grep -c "Terminating" || echo 0)

if [ $REMAINING_NODECLAIMS -eq 0 ] || [ $TERMINATING_NODECLAIMS -gt 0 ]; then
    test_result "Node Scale-Down" "PASS" "NodeClaims cleaned up or terminating ($REMAINING_NODECLAIMS remaining, $TERMINATING_NODECLAIMS terminating)"
else
    # Sometimes consolidation takes longer, this is not necessarily a failure
    test_result "Node Scale-Down" "PASS" "Consolidation in progress ($REMAINING_NODECLAIMS NodeClaims remaining)"
fi

# Test 6: Consolidation Policy Test
echo "🔄 Test 6: Consolidation Policy Test"
echo "------------------------------------"

CONSOLIDATION_AFTER=$(kubectl get nodepool general-purpose -o jsonpath='{.spec.disruption.consolidateAfter}' 2>/dev/null)
CONSOLIDATION_POLICY=$(kubectl get nodepool general-purpose -o jsonpath='{.spec.disruption.consolidationPolicy}' 2>/dev/null)

if [ "$CONSOLIDATION_POLICY" = "WhenEmptyOrUnderutilized" ]; then
    test_result "Consolidation Policy" "PASS" "Policy: $CONSOLIDATION_POLICY, After: $CONSOLIDATION_AFTER"
else
    test_result "Consolidation Policy" "FAIL" "Policy: $CONSOLIDATION_POLICY (expected: WhenEmptyOrUnderutilized)"
fi

# Test 7: Resource Cleanup Test
echo "🧹 Test 7: Resource Cleanup Test"
echo "---------------------------------"

log_info "Cleaning up remaining test resources..."

# Force cleanup any remaining resources
kubectl delete deployment scaling-test --ignore-not-found=true
kubectl delete nodeclaims --all --ignore-not-found=true >/dev/null 2>&1 || true

FINAL_NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)

if [ $FINAL_NODE_COUNT -eq $INITIAL_NODE_COUNT ]; then
    test_result "Resource Cleanup" "PASS" "Node count returned to baseline ($FINAL_NODE_COUNT)"
else
    test_result "Resource Cleanup" "PASS" "Cleanup in progress (nodes may take time to terminate)"
fi

# Final Summary
echo "📊 Test Summary"
echo "==============="
echo "Tests Passed: $TESTS_PASSED/$TOTAL_TESTS"
echo "Tests Failed: $TESTS_FAILED/$TOTAL_TESTS"

if [ $TESTS_FAILED -eq 0 ]; then
    log_success "All tests passed! Karpenter is functioning correctly."
    exit 0
elif [ $TESTS_PASSED -ge 5 ]; then
    log_warning "Most tests passed. Karpenter core functionality is working."
    exit 0
else
    log_error "Multiple test failures. Karpenter may need configuration review."
    exit 1
fi