# create security group for the application load balancer
resource "aws_security_group" "openems_security_group" {
  name        = "${var.project_name}-${var.environment}-openems-sg"
  description = "enable access on ports"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "all traffic"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "all traffic"
    from_port   = 8069
    to_port     = 8069
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "all traffic"
    from_port   = 8086
    to_port     = 8086
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "all traffic"
    from_port   = 8089
    to_port     = 8089
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "all traffic"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "all traffic"
    from_port   = 8087
    to_port     = 8087
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "all traffic"
    from_port   = 8075
    to_port     = 8075
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

ingress {
    description = "all traffic"
    from_port   = 8079
    to_port     = 8079
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

# create security group for the database
resource "aws_security_group" "database_security_group" {
  name        = "${var.project_name}-${var.environment}-database-sg"
  description = "enable Postgres access on port 5432 via openems server sg"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description     = "postgres/aurora access"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.openems_security_group.id]
  }
  #prefix_list_ids are for IP whitelist via managed prefix list
  # is it eiot_dev_ips or "pl-0e76da95670f38f5a"?
  ingress {
    description     = "SSH db troubleshooting tunnel"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    prefix_list_ids = ["pl-0e76da95670f38f5a"]
  }
  ingress {
    description     = "postgres remote troubleshooting"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    prefix_list_ids = ["pl-0e76da95670f38f5a"]
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