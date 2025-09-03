variable "region" {
  description = "AWS region (must match the AMI below)"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project tag"
  type        = string
  default     = "sonarqube-lab"
}

variable "instance_name" {
  description = "EC2 Name tag"
  type        = string
  default     = "sonarqube-ec2"
}

variable "key_name" {
  description = "EC2 key pair name to create & use"
  type        = string
  default     = "sonar"
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to access 22/9000/5432"
  type        = list(string)
  # Strongly recommend replacing with your IP: ["<YOUR_PUBLIC_IP>/32"]
  default     = ["0.0.0.0/0"]
}

variable "user_data" {
  description = "Optional user_data to bootstrap the instance (cloud-init)"
  type        = string
  default     = ""
}
