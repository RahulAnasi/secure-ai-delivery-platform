data "aws_ssm_parameter" "amazon_linux" {
  name            = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  with_decryption = false
}

data "aws_ami" "amazon_linux" {
  owners = ["amazon"]

  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.amazon_linux.value]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "dev" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  subnet_id                   = aws_subnet.dev_public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.dev_server.id]

  iam_instance_profile = aws_iam_instance_profile.dev_ec2.name

  user_data                   = file("${path.module}/bootstrap.sh")
  user_data_replace_on_change = true

  monitoring = false

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "${local.name_prefix}-root"
      Project     = "secure-ai-delivery-platform"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name = "${local.name_prefix}-server"
  }

  depends_on = [
    aws_route.dev_internet,
    aws_route_table_association.dev_public,
    aws_iam_role_policy_attachment.ssm_core
  ]
}