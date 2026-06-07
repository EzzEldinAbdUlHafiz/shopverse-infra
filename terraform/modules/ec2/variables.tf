variable "role" {
  description = "Role of the server for Ansible dynamic inventory"
  type        = string
}

variable "name" {
  description = "Name for the jump server and its resources"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the jump server will be launched"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the jump server"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.medium"
}

variable "volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 20
}

variable "cluster_name" {
  description = "EKS cluster name (for kubeconfig setup in userdata)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "user_data_base64" {
  description = "Base64 encoded user data"
  type        = string
  default     = null
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
