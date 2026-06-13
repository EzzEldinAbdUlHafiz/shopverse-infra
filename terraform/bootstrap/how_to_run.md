Since you are going **local-only** for bootstrap, the workflow is gone and the process becomes straightforward. Here is the exact plan.

---

## 1. Delete the Workflow

```bash
rm .github/workflows/bootstrap.yml
git rm .github/workflows/bootstrap.yml
```

---

## 2. Update `.gitignore` (Add These Lines)

```gitignore
# ── Local bootstrap / Terraform ──
terraform/bootstrap/.terraform/
terraform/bootstrap/.terraform.lock.hcl
terraform/bootstrap/terraform.tfstate
terraform/bootstrap/terraform.tfstate.backup
terraform/bootstrap/terraform.tfstate.*.backup
terraform/bootstrap/backend.tf
terraform/bootstrap/crash.log
terraform/bootstrap/crash.*.log
```

---

## 3. Local Variables File

Create `terraform/bootstrap/terraform.tfvars` locally. **Do not commit it.**

```hcl
project_name      = "shopverse"
aws_region        = "us-east-1"
vpc_cidr          = "10.0.0.0/16"
ecr_repos         = ["frontend", "backend"]
github_org        = "EzzEldinAbdUlHafiz"
github_repo_infra = "shopverse-infra"
github_repo_app   = "shopverse-app"
github_repo_gitops = "shopverse-gitops"
github_branch     = "main"

jenkins_instance_type = "t3.large"
jenkins_ami_id      = "ami-05cf1e9f73fbad2e2"

tags = {
  Project     = "shopverse"
  Environment = "bootstrap"
  ManagedBy   = "terraform"
}
```

---

## 4. Corrected `terraform/bootstrap/main.tf`

Replace the entire file with this. It includes all fixes (ECR lifecycle policy syntax, `file()` instead of `templatefile()`, no import block, no dead `data.aws_ami`).

```hcl
terraform {
  required_version = "~> 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

# ──────────────────────────────────────────────
# Layer 0 prerequisite — read only
# ──────────────────────────────────────────────
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

# ──────────────────────────────────────────────
# S3 State Bucket
# ──────────────────────────────────────────────
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  })
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ──────────────────────────────────────────────
# ECR Repositories
# ──────────────────────────────────────────────
resource "aws_ecr_repository" "repos" {
  for_each = toset(var.ecr_repos)

  name                 = "${var.project_name}-${each.value}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-${each.value}"
  })
}

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 untagged images"
      selection = {
        tagStatus   = "untagged"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# ──────────────────────────────────────────────
# VPC (Public Only)
# ──────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-${count.index}"
  })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ──────────────────────────────────────────────
# Jenkins Security Group — Zero Ingress
# ──────────────────────────────────────────────
resource "aws_security_group" "jenkins" {
  name_prefix = "${var.project_name}-jenkins-"
  vpc_id      = aws_vpc.main.id
  description = "Jenkins - SSM access only, zero ingress"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow outbound for SSM, packages, Git, APIs"
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-jenkins-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ──────────────────────────────────────────────
# Jenkins IAM — Permission Boundary + Role + Policy
# ──────────────────────────────────────────────
resource "aws_iam_policy" "jenkins_boundary" {
  name        = "${var.project_name}-jenkins-boundary"
  description = "Permission boundary for Jenkins role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBootstrapAndMain"
        Effect = "Allow"
        Action = [
          "ec2:*", "eks:*", "rds:*", "iam:*", "s3:*", "ssm:*",
          "ecr:*", "elasticloadbalancing:*", "cloudwatch:*",
          "logs:*", "kms:*", "autoscaling:*", "vpc:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyPrivilegeEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:AttachUserPolicy",
          "iam:PutUserPolicy",
          "iam:CreateAccessKey",
          "iam:CreateAccountAlias"
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  permissions_boundary = aws_iam_policy.jenkins_boundary.arn

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "jenkins_custom" {
  name = "${var.project_name}-jenkins-custom-policy"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
      },
      {
        Sid    = "TerraformMainInfra"
        Effect = "Allow"
        Action = [
          "ec2:*", "eks:*", "rds:*", "iam:*", "elasticloadbalancing:*",
          "cloudwatch:*", "logs:*", "kms:*", "autoscaling:*", "vpc:*"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      },
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-profile"
  role = aws_iam_role.jenkins.name

  tags = var.tags
}

# ──────────────────────────────────────────────
# Jenkins EC2 — No Key Pair, SSM Only, IMDSv2
# ──────────────────────────────────────────────
resource "aws_instance" "jenkins" {
  ami                    = var.jenkins_ami_id
  instance_type          = var.jenkins_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  user_data = file("${path.module}/jenkins-user-data.sh")

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, {
    Name = "${var.project_name}-jenkins"
  })
}

# ──────────────────────────────────────────────
# GitHub App Role — Phase 3 Image Pushes to ECR
# ──────────────────────────────────────────────
resource "aws_iam_role" "github_app" {
  name = "${var.project_name}-github-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = data.aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com",
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo_app}:ref:refs/heads/${var.github_branch}"
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "github_app_perms" {
  name = "${var.project_name}-github-app-perms"
  role = aws_iam_role.github_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"
        ]
        Resource = [for repo in aws_ecr_repository.repos : repo.arn]
      }
    ]
  })
}
```

---

## 5. Exact Steps on your_local_machine

```bash
cd ~/Desktop/grad-project/shopverse/infra-repo/terraform/bootstrap

# 1. Ensure AWS credentials are active (aws configure or env vars)
aws sts get-caller-identity

# 2. Initialize
terraform init

# 3. Plan (optional but recommended)
terraform plan -var-file="terraform.tfvars"

# 4. Apply (creates everything with local state)
terraform apply -var-file="terraform.tfvars"

# 5. Create backend.tf for S3 migration
cat > backend.tf <<'EOF'
terraform {
  backend "s3" {
    bucket       = "shopverse-tfstate-<your-account-id>"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
EOF

# 6. Migrate local state to S3
terraform init -migrate-state

# 7. Clean up local files (keep backend.tf locally for future inits)
rm -f terraform.tfstate terraform.tfstate.backup
rm -rf .terraform .terraform.lock.hcl

# 8. Verify state is in S3
aws s3 ls s3://shopverse-tfstate-<your-account-id>/bootstrap/
```

---

## 6. Future Updates (Local)

Any time you need to change bootstrap resources:

```bash
cd terraform/bootstrap

# backend.tf must exist locally (not in git, but on your machine)
terraform init
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

---

## 7. What to Commit to Git

```bash
cd ~/Desktop/grad-project/shopverse/infra-repo

git rm .github/workflows/bootstrap.yml 2>/dev/null || true

git add terraform/bootstrap/main.tf
git add terraform/bootstrap/variables.tf
git add terraform/bootstrap/outputs.tf
git add terraform/bootstrap/jenkins-user-data.sh
git add terraform/bootstrap/terraform.tfvars.example
git add .gitignore

# DO NOT commit:
# - terraform/bootstrap/terraform.tfvars
# - terraform/bootstrap/backend.tf
# - terraform/bootstrap/terraform.tfstate
# - terraform/bootstrap/.terraform/

git status  # verify
git commit -m "bootstrap: local-only workflow, remove GitHub Actions"
git push origin main
```

---

## 8. Verify Bootstrap Outputs

```bash
# Jenkins instance
aws ec2 describe-instances --filters "Name=tag:Name,Values=shopverse-jenkins" --region us-east-1 --query 'Reservations[0].Instances[0].InstanceId' --output text

# SSM status
aws ssm describe-instance-information --region us-east-1 --query 'InstanceInformationList[*].[InstanceId,PingStatus]' --output table

# ECR repos
aws ecr describe-repositories --repository-names shopverse-frontend shopverse-backend --region us-east-1
```

Once this is done, Phase 1 is complete. Jenkins will handle Phase 2 (Main infra) and GitHub Actions will handle Phase 3 (App delivery via OIDC to ECR).