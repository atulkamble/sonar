# Default VPC & default public subnets
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  # Default subnets in each AZ of the default VPC
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Security Group: SSH(22), SonarQube(9000), PostgreSQL(5432)
resource "aws_security_group" "sonar_sg" {
  name        = "${var.project}-sg"
  description = "Allow SSH(22), SonarQube(9000), and Postgres(5432)"
  vpc_id      = data.aws_vpc.default.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  # SonarQube UI
  ingress {
    description = "SonarQube UI"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  # PostgreSQL
  ingress {
    description = "PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  # Egress (IPv4)
  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
