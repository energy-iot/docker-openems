# Security group for the OpenEMS ECS task.
#
# PR-A posture: the task has a public IP and exposes only the ports the
# stack actually serves. Notably NOT exposed: 8086 (InfluxDB runs without
# auth — localhost-only inside the task) and 8080/8087 (nothing listens).
# PR-C replaces direct exposure with an ALB + TLS and closes these to the
# ALB security group only.
resource "aws_security_group" "openems_security_group" {
  name        = "${var.project_name}-${var.environment}-openems-sg"
  description = "OpenEMS ECS task ingress"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "OpenEMS web UI (nginx)"
    from_port   = 8089
    to_port     = 8089
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Ui.Websocket (browser to backend)"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Edge.Websocket (field/local edges connect here)"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Backend2Backend REST (MBE)"
    from_port   = 8075
    to_port     = 8075
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Odoo admin (temporary until PR-C moves it behind SSM/ALB)"
    from_port   = 8069
    to_port     = 8069
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-openems-sg"
  }
}

# Security group for the RDS Postgres instance: reachable only from the
# ECS task's security group. No CIDR rules, no SSH (RDS is managed — there
# is nothing to SSH into).
resource "aws_security_group" "database_security_group" {
  name        = "${var.project_name}-${var.environment}-database-sg"
  description = "Postgres access from the OpenEMS task only"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description     = "postgres from ECS task"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.openems_security_group.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-database-sg"
  }
}
