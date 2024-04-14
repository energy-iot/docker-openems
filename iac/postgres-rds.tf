# create database subnet group
resource "aws_db_subnet_group" "database_subnet_group" {
  name        = "${var.project_name}-${var.environment}-subnet-group"
  subnet_ids  = [aws_subnet.private_data_subnet_az1.id, aws_subnet.private_data_subnet_az2.id]
  description = "subnet group to which the rds instance will be created"

  tags = {
    Name = "${var.project_name}-${var.environment}-subnet-group"
  }
}

# create the rds instance
resource "aws_db_instance" "database_instance" {
  engine                 = var.engine_type
  engine_version         = var.engine_type_version
  multi_az               = var.multi_az_deployment
  identifier             = var.database_cluster_name
  username               = var.master_username
  password               = var.master_password
  db_name                = var.initial_database_name
  instance_class         = var.instance_class_type
  allocated_storage      = 200
  db_subnet_group_name   = aws_db_subnet_group.database_subnet_group.id
  vpc_security_group_ids = [aws_security_group.database_security_group.id]
  availability_zone      = data.aws_availability_zones.available_zones.names[1]
  skip_final_snapshot    = true
  publicly_accessible    = false
}