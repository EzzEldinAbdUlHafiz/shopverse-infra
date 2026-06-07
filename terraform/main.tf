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
# EKS Access Entry — jump server role
# ──────────────────────────────────────────────
resource "aws_eks_access_entry" "jump_server" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.jump_server[0].iam_role_arn
  type          = "STANDARD"

  tags = local.common_tags
}

resource "aws_eks_access_policy_association" "jump_server_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.jump_server[0].iam_role_arn
  policy_arn    = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.jump_server]
}

# ──────────────────────────────────────────────
# EC2 Jump Server Module
# ──────────────────────────────────────────────
module "jump_server" {
  source = "./modules/ec2"
  count  = var.create_jump_server ? 1 : 0

  name              = "${var.project_name}-jump-server"
  vpc_id            = module.vpc.vpc_id
  subnet_id         = module.vpc.private_subnet_ids[0] # Private subnet as per plan
  instance_type     = var.jump_server_instance_type
  cluster_name      = var.cluster_name
  aws_region        = var.aws_region
  role              = "human-access"
  tags              = local.common_tags

  # Base64 empty or minimal userdata for jump server
  user_data_base64  = base64encode("#!/bin/bash\necho 'Jump server initialized'")
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
# ──────────────────────────────────────────────
resource "aws_security_group_rule" "rds_eks_ingress" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = module.rds.rds_security_group_id
  source_security_group_id = module.eks.node_security_group_id
}

# ──────────────────────────────────────────────
# EKS Security Group — Jenkins access
# ──────────────────────────────────────────────
# Since Jenkins was created in Bootstrap phase, we need its Security Group ID.
# We can find it by tag or use a data source.
data "aws_security_group" "jenkins" {
  filter {
    name   = "group-name"
    values = ["${var.project_name}-jenkins-sg"]
  }
}

resource "aws_security_group_rule" "eks_from_jenkins" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_security_group_id
  source_security_group_id = data.aws_security_group.jenkins.id
  description              = "Jenkins access to EKS API"
}
