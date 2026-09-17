resource "aws_security_group" "openems" {
  name        = "${var.project_name}-${var.environment}-stack-sg"
  description = "Scoped access to dev OpenEMS stack (UI, B2B, Odoo)"
  vpc_id      = aws_vpc.main.id

  # OpenEMS UI (nginx)
  ingress {
    description = "OpenEMS UI"
    from_port   = 4200
    to_port     = 4200
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips
  }

  # OpenEMS Backend B2B REST (used by MBE)
  ingress {
    description = "OpenEMS Backend B2B REST"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips
  }

  # Odoo web UI
  ingress {
    description = "Odoo"
    from_port   = 10016
    to_port     = 10016
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips
  }

  # InfluxDB HTTP (optional — for debugging)
  ingress {
    description = "InfluxDB HTTP"
    from_port   = 8086
    to_port     = 8086
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips
  }

  # NOTE: no SSH ingress — use SSM Session Manager for shell access.

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-stack-sg"
  }
}
