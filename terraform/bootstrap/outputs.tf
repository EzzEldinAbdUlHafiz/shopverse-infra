output "tfstate_bucket_name" {
  description = "Name of the S3 bucket used for Terraform state"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tfstate_bucket_arn" {
  description = "ARN of the S3 state bucket"
  value       = aws_s3_bucket.tfstate.arn
}

output "tfstate_bucket_region" {
  description = "Region of the S3 state bucket"
  value       = var.aws_region
}

output "ecr_repository_urls" {
  description = "URLs of the created ECR repositories"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "ecr_repository_arns" {
  description = "ARNs of the created ECR repositories"
  value       = { for k, v in aws_ecr_repository.repos : k => v.arn }
}

output "vpc_id" {
  description = "ID of the bootstrap VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "jenkins_instance_id" {
  description = "Instance ID of the Jenkins server"
  value       = aws_instance.jenkins.id
}

output "jenkins_security_group_id" {
  description = "Security group ID of the Jenkins server"
  value       = aws_security_group.jenkins.id
}

output "github_app_role_arn" {
  description = "ARN of the GitHub app role for Phase 3 ECR pushes"
  value       = aws_iam_role.github_app.arn
}

output "remote_backend_config" {
  description = "Backend configuration for S3 state"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.tfstate.bucket}"
        key          = "bootstrap/terraform.tfstate"
        region       = "${var.aws_region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}
