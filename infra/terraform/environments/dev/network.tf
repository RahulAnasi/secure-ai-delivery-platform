locals {
  name_prefix = "secure-ai-dev"
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

resource "aws_vpc" "dev" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_subnet" "dev_public" {
  vpc_id                  = aws_vpc.dev.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-subnet"
  }
}

resource "aws_internet_gateway" "dev" {
  vpc_id = aws_vpc.dev.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_route_table" "dev_public" {
  vpc_id = aws_vpc.dev.id

  tags = {
    Name = "${local.name_prefix}-public-routes"
  }
}

resource "aws_route" "dev_internet" {
  route_table_id         = aws_route_table.dev_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.dev.id
}

resource "aws_route_table_association" "dev_public" {
  subnet_id      = aws_subnet.dev_public.id
  route_table_id = aws_route_table.dev_public.id
}

resource "aws_security_group" "dev_server" {
  name        = "${local.name_prefix}-server"
  description = "Development server with no inbound access"
  vpc_id      = aws_vpc.dev.id

  tags = {
    Name = "${local.name_prefix}-server"
  }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.dev_server.id
  description       = "Outbound HTTPS for AWS services and package downloads"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}