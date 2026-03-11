// Existing Terraform src code found at /var/folders/dv/rwkhhnhs4c9frqn6rc7njm6h0000gn/T/terraform_src.

# TERRAFORM BLOCK 

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWS PROVIDER 
provider "aws" {
  region = var.aws_region
}

# VARIABLES

variable "aws_region" {
  type = string
  description = "AWS region to deploy into"
}

variable "key_name" {
  type = string
  description = "Name of an existing EC2 key pair to allow SSH access"
}

variable "my_ip" {
  type = string
  description = "Your public IP in CIDR form, e.g. 1.2.3.4/32"
}

variable "vpc_id" {
  type = string
  description = "VPC to launch into"
}

variable "subnet_id" {
  type = string
  description = "Public subnet where the EC2 instance will launch"
}

variable "repo_url" {
  type = string
  description = "URL of your forked anomaly-detection repo"
  default = "https://github.com/jeffreyzhang10/anomaly-detection.git"
}

variable "uva_id" {
  type = string
  description = "Your UVA Computing ID"
}

# DATA SOURCES

data "aws_caller_identity" "current" {}

# ami lookup 
data "aws_ssm_parameter" "latest_ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# LOCAL VARIABLES

locals {
  bucket_name = "${var.uva_id}-ds5220-dp1-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

# SECURITY GROUP

resource "aws_security_group" "app_sg" {
  name = "${var.uva_id}-ds5220-dp1-sg"
  description = "Allow SSH and FastAPI"
  vpc_id = var.vpc_id

  ingress {
    description = "Lets me SSH from my IP only"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = [var.my_ip]
  }

  # fast API rule HERE 
  ingress {
    description = "FastAPI from anywhere"
    from_port = 8000
    to_port = 8000
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # outbound traffic here 
  egress {
    description = "Allow all outbound traffic"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ds5220-dp1-sg"
  }
}

# S3 BUCKET

resource "aws_s3_bucket" "data_bucket" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "data_bucket_pab" {
  bucket = aws_s3_bucket.data_bucket.id

  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

# SNS TOPIC & POLICY

resource "aws_sns_topic" "sns_topic" {
  name = "${var.uva_id}-ds5220-dp1" # cannot be hard coded 
}

resource "aws_sns_topic_policy" "sns_topic_policy" {
  arn = aws_sns_topic.sns_topic.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "AllowS3Publish"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = "sns:Publish"
        Resource = aws_sns_topic.sns_topic.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.data_bucket.arn
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.data_bucket.id

  topic {
    topic_arn = aws_sns_topic.sns_topic.arn
    events = ["s3:ObjectCreated:*"]

    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sns_topic_policy.sns_topic_policy]
}

# IAM ROLE & INSTANCE PROFILE

resource "aws_iam_role" "ec2_role" {
  name = "${var.uva_id}-ds5220-dp1-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "bucket_only_access" {
  name = "BucketOnlyAccess"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = aws_s3_bucket.data_bucket.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.data_bucket.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "${var.uva_id}-ds5220-dp1-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 INSTANCE


resource "aws_instance" "app_instance" {
  ami = data.aws_ssm_parameter.latest_ubuntu_ami.value
  instance_type = "t3.micro"
  key_name = var.key_name
  subnet_id = var.subnet_id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    apt-get install -y python3 python3-venv python3-pip git

    cd /home/ubuntu
    git clone ${var.repo_url} app
    chown -R ubuntu:ubuntu /home/ubuntu/app

    cd /home/ubuntu/app
    sudo -u ubuntu python3 -m venv venv
    sudo -u ubuntu /home/ubuntu/app/venv/bin/pip install --upgrade pip
    sudo -u ubuntu /home/ubuntu/app/venv/bin/pip install -r requirements.txt

    export BUCKET_NAME=${aws_s3_bucket.data_bucket.bucket}
    echo "BUCKET_NAME=${aws_s3_bucket.data_bucket.bucket}" >> /etc/environment

    cat > /etc/systemd/system/anomaly-api.service <<SYSTEMD_EOF
    [Unit]
    Description=FastAPI anomaly detection service
    After=network.target

    [Service]
    User=ubuntu
    WorkingDirectory=/home/ubuntu/app
    Environment=BUCKET_NAME=${aws_s3_bucket.data_bucket.bucket}
    ExecStart=/home/ubuntu/app/venv/bin/fastapi run app.py --host 0.0.0.0 --port 8000
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SYSTEMD_EOF

    systemctl daemon-reload
    systemctl enable anomaly-api
    systemctl start anomaly-api
  EOF

  tags = {
    Name = "ds5220-dp1-ec2"
  }
}

# ELASTIC IP

resource "aws_eip" "app_eip" {
  domain = "vpc"
}

resource "aws_eip_association" "app_eip_assoc" {
  instance_id = aws_instance.app_instance.id
  allocation_id = aws_eip.app_eip.id
}


# SNS SUBSCRIPTION

resource "aws_sns_topic_subscription" "sns_subscription" {
  topic_arn = aws_sns_topic.sns_topic.arn
  protocol = "http"
  endpoint = "http://${aws_eip.app_eip.public_ip}:8000/notify"

  depends_on = [aws_eip_association.app_eip_assoc]
}

# OUTPUTS

output "instance_id" {
  value = aws_instance.app_instance.id
}

output "elastic_ip" {
  value = aws_eip.app_eip.public_ip
}

output "bucket_name" {
  value = aws_s3_bucket.data_bucket.bucket
}

output "topic_arn" {
  value = aws_sns_topic.sns_topic.arn
}

output "api_url" {
  value = "http://${aws_eip.app_eip.public_ip}:8000/docs"
}

output "notify_url" {
  value = "http://${aws_eip.app_eip.public_ip}:8000/notify"
}