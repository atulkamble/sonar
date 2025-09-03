output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.sonar.id
}

output "public_ip" {
  description = "Public IPv4"
  value       = aws_instance.sonar.public_ip
}

output "public_dns" {
  description = "Public DNS name"
  value       = aws_instance.sonar.public_dns
}

output "security_group_id" {
  description = "Security Group ID"
  value       = aws_security_group.sonar_sg.id
}

output "ssh_key_path" {
  description = "Path to the generated private key"
  value       = pathexpand("~/${var.key_name}.pem")
}

output "ssh_command" {
  description = "Copy-paste SSH command"
  value       = "ssh -i ~/${var.key_name}.pem ec2-user@${aws_instance.sonar.public_ip}"
}

output "sonarqube_url" {
  description = "URL to access SonarQube UI (after you install & start it)"
  value       = "http://${aws_instance.sonar.public_ip}:9000"
}
