region        = "us-east-1"
project       = "sonarqube-lab"
instance_name = "sonarqube-ec2"
key_name      = "sonar"

# Replace with your IP for better security:
# allowed_cidrs = ["203.0.113.45/32"]
allowed_cidrs = ["0.0.0.0/0"]
