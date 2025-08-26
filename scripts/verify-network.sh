#!/bin/bash

# Network Verification Script for EKS Deployment
# This script verifies that the VPC network is properly configured before deploying EKS nodes
# Author: jasontsai

set -e

echo "=== EKS Network Configuration Verification ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get VPC ID from Terraform output or environment variable
if [ -z "$VPC_ID" ]; then
    VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
fi

if [ -z "$VPC_ID" ]; then
    echo -e "${RED}Error: VPC_ID not found. Please set VPC_ID environment variable or run from Terraform directory.${NC}"
    exit 1
fi

echo "VPC ID: $VPC_ID"
echo ""

# Function to check and report status
check_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
        return 1
    fi
}

# 1. Check VPC exists
echo "1. Checking VPC..."
vpc_info=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID 2>/dev/null || echo "")
if [ -n "$vpc_info" ]; then
    vpc_cidr=$(echo $vpc_info | jq -r '.Vpcs[0].CidrBlock')
    check_status 0 "VPC exists with CIDR: $vpc_cidr"
else
    check_status 1 "VPC not found"
    exit 1
fi
echo ""

# 2. Check Subnets
echo "2. Checking Subnets..."
private_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Tier,Values=Private" --query "Subnets[].SubnetId" --output text)
public_subnets=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Tier,Values=Public" --query "Subnets[].SubnetId" --output text)

private_count=$(echo $private_subnets | wc -w)
public_count=$(echo $public_subnets | wc -w)

check_status 0 "Found $private_count private subnets"
check_status 0 "Found $public_count public subnets"

if [ $private_count -eq 0 ]; then
    echo -e "${RED}Warning: No private subnets found. EKS nodes should be in private subnets.${NC}"
fi
echo ""

# 3. Check Internet Gateway
echo "3. Checking Internet Gateway..."
igw=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text)
if [ "$igw" != "None" ] && [ -n "$igw" ]; then
    check_status 0 "Internet Gateway attached: $igw"
else
    check_status 1 "No Internet Gateway found"
fi
echo ""

# 4. Check NAT Gateways
echo "4. Checking NAT Gateways..."
nat_gateways=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" --query "NatGateways[].NatGatewayId" --output text)
nat_count=$(echo $nat_gateways | wc -w)

if [ $nat_count -gt 0 ]; then
    check_status 0 "Found $nat_count NAT Gateway(s)"
    for nat in $nat_gateways; do
        echo "  - $nat"
    done
else
    check_status 1 "No NAT Gateways found"
    echo -e "${RED}Critical: Private subnets need NAT Gateway for internet access${NC}"
fi
echo ""

# 5. Check Route Tables - CRITICAL CHECK
echo "5. Checking Route Tables (CRITICAL)..."
echo ""

# Check private subnet routes
echo "Private Subnet Routes:"
route_ok=true
for subnet in $private_subnets; do
    echo "  Subnet: $subnet"
    
    # Get route table for this subnet
    route_table=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)
    
    if [ "$route_table" == "None" ] || [ -z "$route_table" ]; then
        # Check main route table
        route_table=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --query "RouteTables[0].RouteTableId" --output text)
        echo "    Using main route table: $route_table"
    else
        echo "    Route table: $route_table"
    fi
    
    # Check for 0.0.0.0/0 route to NAT Gateway
    nat_route=$(aws ec2 describe-route-tables --route-table-ids $route_table --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" --output text 2>/dev/null)
    
    if [ -n "$nat_route" ] && [ "$nat_route" != "None" ]; then
        check_status 0 "  Has route to NAT Gateway: $nat_route"
    else
        check_status 1 "  MISSING route to NAT Gateway!"
        route_ok=false
        
        # Provide fix command
        if [ $nat_count -gt 0 ]; then
            first_nat=$(echo $nat_gateways | awk '{print $1}')
            echo -e "${YELLOW}    Fix command:${NC}"
            echo "    aws ec2 create-route --route-table-id $route_table --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $first_nat"
        fi
    fi
done
echo ""

# Check public subnet routes
echo "Public Subnet Routes:"
for subnet in $public_subnets; do
    echo "  Subnet: $subnet"
    
    # Get route table for this subnet
    route_table=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet" --query "RouteTables[0].RouteTableId" --output text 2>/dev/null)
    
    if [ "$route_table" == "None" ] || [ -z "$route_table" ]; then
        route_table=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --query "RouteTables[0].RouteTableId" --output text)
        echo "    Using main route table: $route_table"
    else
        echo "    Route table: $route_table"
    fi
    
    # Check for 0.0.0.0/0 route to Internet Gateway
    igw_route=$(aws ec2 describe-route-tables --route-table-ids $route_table --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" --output text 2>/dev/null)
    
    if [ -n "$igw_route" ] && [ "$igw_route" != "None" ] && [ "$igw_route" != "local" ]; then
        check_status 0 "  Has route to Internet Gateway: $igw_route"
    else
        check_status 1 "  MISSING route to Internet Gateway!"
        
        # Provide fix command
        if [ -n "$igw" ]; then
            echo -e "${YELLOW}    Fix command:${NC}"
            echo "    aws ec2 create-route --route-table-id $route_table --destination-cidr-block 0.0.0.0/0 --gateway-id $igw"
        fi
    fi
done
echo ""

# 6. Check Security Groups
echo "6. Checking Security Groups..."
sg_count=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups | length(@)" --output text)
check_status 0 "Found $sg_count security group(s) in VPC"
echo ""

# 7. Summary
echo "=== Verification Summary ==="
echo ""

if [ "$route_ok" = true ] && [ $nat_count -gt 0 ]; then
    echo -e "${GREEN}✓ Network configuration is correct for EKS deployment${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Deploy EKS cluster: terraform apply -target=aws_eks_cluster.main"
    echo "2. Deploy node groups: terraform apply -target=aws_eks_node_group.main"
    exit 0
else
    echo -e "${RED}✗ Network configuration issues detected${NC}"
    echo ""
    echo "Critical issues to fix:"
    if [ $nat_count -eq 0 ]; then
        echo "- No NAT Gateway found. Private subnets need NAT for internet access."
    fi
    if [ "$route_ok" = false ]; then
        echo "- Private subnet routes to NAT Gateway are missing."
        echo "  Nodes in private subnets won't be able to join the cluster."
    fi
    echo ""
    echo -e "${YELLOW}Fix these issues before deploying EKS nodes!${NC}"
    exit 1
fi