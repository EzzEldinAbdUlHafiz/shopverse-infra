output "tfstate_bucket_name" {
  value = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_urls" {
  value = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "bastion_public_ip" {
  description = "Public IP of the bastion host for SSH"
  value       = aws_instance.bastion.public_ip
}

output "bastion_instance_id" {
  value = aws_instance.bastion.id
}

output "github_app_role_arn" {
  value = aws_iam_role.github_app.arn
}