# Security group for the OpenEMS ECS task.
#
# PR-C posture: the task no longer takes public traffic directly. Only the
# ALB security group may reach the three served ports; TLS terminates at the
# ALB. Everything else is closed: Odoo (8069) and Backend2Backend (8075/8079)
# are reachable only via ECS Exec / SSM, and InfluxDB (8086) stays
# localhost-only inside the task.
resource "aws_security_group" "openems_security_group" {
  name        = "${var.project_name}-${var.environment}-openems-sg"
  description = "OpenEMS ECS task ingress"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description     = "OpenEMS web UI (nginx) from ALB"
    from_port       = 8089
    to_port         = 8089
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Ui.Websocket from ALB"
    from_port       = 8082
    to_port         = 8082
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Edge.Websocket from ALB"
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Backend2Backend REST (MBE) from ALB"
    from_port       = 8075
    to_port         = 8075
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
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
