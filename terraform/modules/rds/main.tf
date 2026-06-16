# ──────────────────────────────────────────────
# DB Subnet Group
# ──────────────────────────────────────────────
resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.name}-subnet-group"
  })
}

# ──────────────────────────────────────────────
# DB Security Group
# ──────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name_prefix = "${var.name}-rds-"
  description = "Security group for RDS MySQL"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-rds-sg"
  })
}

# ──────────────────────────────────────────────
# RDS Instance
# ──────────────────────────────────────────────
resource "aws_db_instance" "this" {
  identifier             = var.name
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Performance & Cost
  multi_az            = true
  publicly_accessible = false
  skip_final_snapshot = true
  storage_encrypted   = true

  # Backup policy (RDS basic)
  backup_retention_period = 1
  backup_window           = "03:00-04:00"

  tags = merge(var.tags, {
    Name = var.name
  })
}
