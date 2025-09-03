# EC2 Instance
resource "aws_instance" "sonar" {
  ami                         = "ami-00ca32bbc84273381"   # us-east-1
  instance_type               = "t3.medium"
  subnet_id                   = data.aws_subnets.default_public.ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.sonar_sg.id]

  # Use the auto-generated keypair
  key_name = aws_key_pair.generated.key_name

  user_data = var.user_data

  # Root volume: 50 GB gp3
  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
    # Optional tuning:
    # iops       = 3000
    # throughput = 125
  }

  tags = {
    Name = var.instance_name
  }
}
