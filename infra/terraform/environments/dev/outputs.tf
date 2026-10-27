output "aws_account_id" {
  description = "AWS account used by this configuration."
  value       = data.aws_caller_identity.current.account_id
}

output "terraform_identity_arn" {
  description = "AWS identity used by the Terraform provider."
  value       = data.aws_caller_identity.current.arn
}

output "vpc_id" {
  description = "Development VPC ID."
  value       = aws_vpc.dev.id
}

output "subnet_id" {
  description = "Development public subnet ID."
  value       = aws_subnet.dev_public.id
}

output "server_security_group_id" {
  description = "Security group assigned to the development server."
  value       = aws_security_group.dev_server.id
}

output "availability_zone" {
  description = "Availability Zone containing the development subnet."
  value       = aws_subnet.dev_public.availability_zone
}

output "instance_id" {
  description = "Development EC2 instance ID."
  value       = aws_instance.dev.id
}

output "instance_public_ip" {
  description = "Development server public IPv4 address."
  value       = aws_instance.dev.public_ip
}

output "instance_role_arn" {
  description = "IAM role assumed by the development server."
  value       = aws_iam_role.dev_ec2.arn
}

output "ami_id" {
  description = "Amazon Linux image used by the development server."
  value       = data.aws_ami.amazon_linux.id
}

output "delivery_bucket_name" {
  description = "Private bucket used to deliver application artifacts."
  value       = aws_s3_bucket.delivery.id
}

output "artifact_object_key" {
  description = "Exact object key allowed for the selected artifact."
  value       = local.artifact_object_key
}

output "runtime_secret_arn" {
  description = "Existing secret whose value the EC2 role may retrieve."
  value       = data.aws_secretsmanager_secret.model_key.arn
}