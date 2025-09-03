# 1) Generate a fresh private key (RSA 4096)
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# 2) Save the private key locally as ~/sonar.pem with 0600 perms
resource "local_file" "private_key_pem" {
  filename        = pathexpand("~/${var.key_name}.pem")
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

# 3) (Optional) Save the public key too as ~/sonar.pub
resource "local_file" "public_key" {
  filename        = pathexpand("~/${var.key_name}.pub")
  content         = tls_private_key.ssh.public_key_openssh
  file_permission = "0644"
}

# 4) Register the public key in AWS as an EC2 key pair
resource "aws_key_pair" "generated" {
  key_name   = var.key_name
  public_key = tls_private_key.ssh.public_key_openssh
}
