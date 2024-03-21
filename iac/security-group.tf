# create security group for the application load balancer
resource "aws_security_group" "openems_security_group" {
  name        = "${var.project_name}-${var.environment}-openems-sg"
  description = "enable access on port 80/8089"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "all traffic"
    from_port   = 8089
    to_port     = 8089
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "all traffic"
<<<<<<< HEAD
<<<<<<< HEAD
<<<<<<< HEAD
    from_port   = 8069
    to_port     = 8089
=======
    from_port   = 8079
    to_port     = 8079
>>>>>>> e566370 (Update exposed ports through sg)
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

<<<<<<< HEAD
  ingress {
    description = "all traffic"
=======
>>>>>>> de34f82 (updated security group)
=======

  ingress {
    description = "all traffic"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  ingress {
    description = "all traffic"
>>>>>>> e566370 (Update exposed ports through sg)
=======
>>>>>>> 39ef6f0 (commit)
    from_port   = 80
    to_port     = 80
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
<<<<<<< HEAD
}
<<<<<<< HEAD


# create security group for the database
resource "aws_security_group" "database_security_group" {
  name        = "${var.project_name}-${var.environment}-database-sg"
  description = "enable MySQL/Aurora access on port 3306 via app server sg"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description     = "mysql/aurora access"
    from_port       = 3306
    to_port         = 3306
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
=======
>>>>>>> e566370 (Update exposed ports through sg)
=======
}
>>>>>>> 39ef6f0 (commit)
