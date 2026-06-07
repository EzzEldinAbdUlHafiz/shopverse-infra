output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IP of the instance"
  value       = aws_instance.this.public_ip
}

output "private_ip" {
  description = "Private IP of the instance"
  value       = aws_instance.this.private_ip
}

output "public_dns" {
  description = "Public DNS of the instance"
  value       = aws_instance.this.public_dns
}

output "security_group_id" {
  description = "Security group ID of the instance"
  value       = aws_security_group.this.id
}

output "iam_role_arn" {
  description = "IAM role ARN attached to the instance"
  value       = aws_iam_role.instance.arn
}

output "iam_role_name" {
  description = "IAM role name attached to the instance"
  value       = aws_iam_role.instance.name
}

output "console_connect_url" {
  description = "AWS Console URL to connect to the instance"
  value       = "https://console.aws.amazon.com/ec2/v2/home?#ConnectToInstance:instanceId=${aws_instance.this.id}"
}
