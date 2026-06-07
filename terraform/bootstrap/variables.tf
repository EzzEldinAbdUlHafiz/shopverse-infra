variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
}

variable "aws_region" {
  description = "AWS region to deploy bootstrap resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the bootstrap VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "ecr_repos" {
  description = "List of ECR repository names to create"
  type        = list(string)
  default     = ["frontend", "backend"]
}

variable "github_org" {
  description = "GitHub organization name"
  type        = string
}

variable "github_repo_infra" {
  description = "GitHub repository name for infrastructure"
  type        = string
}

variable "github_repo_app" {
  description = "GitHub repository name for application"
  type        = string
}

variable "github_repo_gitops" {
  description = "GitHub repository name for GitOps"
  type        = string
}

variable "github_branch" {
  description = "GitHub branch to pin for OIDC trust"
  type        = string
  default     = "main"
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "m7i-flex.large"
}

variable "jenkins_ami_id" {
  description = "AMI ID for Jenkins EC2 (Ubuntu 24.04 LTS x86_64)"
  type        = string
  default     = "ami-05cf1e9f73fbad2e2"
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
