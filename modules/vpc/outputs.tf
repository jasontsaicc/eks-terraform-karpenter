output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "公開子網路 IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "私有子網路 IDs"
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "資料庫子網路 IDs"
  value       = aws_subnet.database[*].id
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs"
  value       = aws_nat_gateway.main[*].id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "公開路由表 ID"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "私有路由表 IDs"
  value       = aws_route_table.private[*].id
}