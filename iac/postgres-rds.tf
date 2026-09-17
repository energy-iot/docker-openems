# create database subnet group
resource "aws_db_subnet_group" "database_subnet_group" {
  name        = "${var.project_name}-${var.environment}-subnet-group"
  subnet_ids  = [aws_subnet.private_data_subnet_az1.id, aws_subnet.private_data_subnet_az2.id]
  description = "subnet group to which the rds instance will be created"

  tags = {
    Name = "${var.project_name}-${var.environment}-subnet-group"
  }
}

# RDS Postgres — holds the Odoo database only (edge registry, apikeys,
# users, setup protocols). Telemetry lives in InfluxDB, never here.
# Odoo creates its application database ("openems") itself during the
# one-time init (see the PR-A runbook); db_name below is just the initial
# placeholder database RDS creates.
resource "aws_db_instance" "database_instance" {
  engine                 = var.engine_type
  engine_version         = var.engine_type_version
  multi_az               = var.multi_az_deployment
  identifier             = var.database_cluster_name
  username               = var.master_username
  password               = random_password.db.result
  db_name                = var.initial_database_name
  instance_class         = var.instance_class_type
  allocated_storage      = 20 # 20 GB is plenty for the Odoo DB; RDS storage can be grown later but never shrunk
  storage_encrypted      = true
  db_subnet_group_name   = aws_db_subnet_group.database_subnet_group.id
  vpc_security_group_ids = [aws_security_group.database_security_group.id]
  availability_zone      = data.aws_availability_zones.available_zones.names[1]
  publicly_accessible    = false

  # BUILDOUT settings — the DB is empty and gets recreated as we iterate.
  # RE-HARDEN before production use: deletion_protection = true,
  # skip_final_snapshot = false (+ final_snapshot_identifier), and raise
  # backup_retention_period. See the aws-arch-v2 plan.
  deletion_protection     = false
  backup_retention_period = 1
  skip_final_snapshot     = true
}
