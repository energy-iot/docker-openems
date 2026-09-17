# Ubuntu 22.04 LTS (Canonical official AMI)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "openems" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.openems.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  # Enforce IMDSv2
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    git_branch = var.git_branch
    edge_count = var.edge_count
  })

  # user_data changes should NOT replace the instance — it only runs on first boot.
  # If you need to re-bootstrap, destroy and recreate the instance explicitly.
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-stack"
  }
}
