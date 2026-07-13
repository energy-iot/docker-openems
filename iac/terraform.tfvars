# environment variables
region       = "us-east-1"
project_name = "openems"
environment  = "deployment"

# vpc variables
vpc_cidr                     = "10.0.0.0/16"
public_subnet_az1_cidr       = "10.0.0.0/24"
public_subnet_az2_cidr       = "10.0.1.0/24"
private_data_subnet_az1_cidr = "10.0.2.0/24"
private_data_subnet_az2_cidr = "10.0.3.0/24"

# ecs variables — edges are NOT deployed to AWS (they run in the field)
architecture               = "X86_64"
image_name_openems_ui      = "openems-ui"
image_name_openems_backend = "openems-backend"
image_name_odoo            = "odoo"
image_tag                  = "latest"

# rds variables
# Postgres 15: matches Odoo 16 support and the local dev data/image.
# Major-only version lets RDS pick the current minor.
# No master_password here — Terraform generates it into Secrets Manager.
engine_type           = "postgres"
engine_type_version   = "15"
multi_az_deployment   = "false"
database_cluster_name = "odoodb"
master_username       = "odoo"
initial_database_name = "odoodb"
instance_class_type   = "db.t3.micro"
