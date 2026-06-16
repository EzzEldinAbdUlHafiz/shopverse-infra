output "vpc_id" {
  description = "VPC ID"
  value       = local.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = var.vpc_cidr
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = var.existing_vpc_id == null ? aws_subnet.public[*].id : data.aws_subnets.public_bootstrap[0].ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "private_app_subnet_ids" {
  description = "List of private app subnet IDs (for EKS nodes)"
  value       = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  description = "List of private data subnet IDs (for RDS)"
  value       = aws_subnet.private_data[*].id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = var.existing_vpc_id == null ? aws_internet_gateway.this[0].id : null
}

output "nat_gateway_id" {
  description = "NAT Gateway ID"
  value       = aws_nat_gateway.this.id
}
