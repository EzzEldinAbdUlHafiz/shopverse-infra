locals {
  common_tags = {
    Project     = var.project_name
    ManagedBy   = "terraform"
    Environment = "production"
  }
}

# ──────────────────────────────────────────────
# VPC Module
# ──────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  name         = var.project_name
  vpc_cidr     = var.vpc_cidr
  cluster_name = var.cluster_name
  aws_region   = var.aws_region
  tags         = local.common_tags
}

# ──────────────────────────────────────────────
# EKS Module
# ──────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  node_min_size      = var.node_min_size
  node_max_size      = var.node_max_size
  tags               = local.common_tags
}

# ──────────────────────────────────────────────
# EKS Access Entry — Bastion (CI/CD bridge)
# ──────────────────────────────────────────────
data "aws_iam_role" "bastion" {
  name = "${var.project_name}-bastion-role"
}

resource "aws_eks_access_entry" "bastion" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_role.bastion.arn
  type          = "STANDARD"

  tags = local.common_tags
}

resource "aws_eks_access_policy_association" "bastion_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.bastion]
}

# ──────────────────────────────────────────────
# RDS Module
# ──────────────────────────────────────────────
module "rds" {
  source = "./modules/rds"

  name               = "${var.project_name}-db"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  db_username        = var.db_username
  db_password        = var.db_password
  db_name            = var.db_name
  tags               = local.common_tags
}

# ──────────────────────────────────────────────
# RDS Connectivity — EKS Nodes to RDS
# Uses the node security group for the ingress rule
# ──────────────────────────────────────────────
resource "aws_security_group_rule" "rds_eks_ingress" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = module.rds.rds_security_group_id
  source_security_group_id = module.eks.node_security_group_id
}
