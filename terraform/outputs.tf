# ──────────────────────────────────────────────
# VPC
# ──────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

# ──────────────────────────────────────────────
# EKS
# ──────────────────────────────────────────────
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority" {
  description = "EKS cluster CA certificate (base64)"
  value       = module.eks.cluster_certificate_authority
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID of the EKS cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "eks_managed_security_group_id" {
  description = "EKS-managed cluster security group (attached to nodes)"
  value       = module.eks.eks_managed_security_group_id
}

output "node_group_role_arn" {
  description = "IAM role ARN for the node group"
  value       = module.eks.node_group_role_arn
}

output "node_group_role_name" {
  description = "IAM role name for the node group (used for policy attachment)"
  value       = module.eks.node_group_role_name
}

output "alb_controller_role_arn" {
  description = "IAM role ARN for the ALB controller"
  value       = module.eks.alb_controller_role_arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN for the EBS CSI driver"
  value       = module.eks.ebs_csi_role_arn
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL"
  value       = module.eks.oidc_provider_url
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "eso_irsa_role_arn" {
  description = "IAM role ARN for External Secrets Operator (IRSA)"
  value       = module.eks.eso_irsa_role_arn
}

output "rds_endpoint" {
  description = "RDS MySQL endpoint"
  value       = module.rds.rds_endpoint
}