variable "name" {
  description = "Name prefix for all VPC resources"
  type        = string
}

variable "aws_region" {
  description = "AWS region for VPC endpoints"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "existing_vpc_id" {
  description = "Existing VPC ID to reuse (from bootstrap). If null, creates a new VPC."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "EKS cluster name (used for subnet tagging)"
  type        = string
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
