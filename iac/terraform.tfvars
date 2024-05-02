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

# ecs variables
architecture = "X86_64"
image_name_openems_ui = "openems-ui"
image_name_openems_backend = "openems-backend"
image_name_openems_edge = "openems-edge"
image_name_openems_db = "openems-db"
image_name_odoo = "odoo"
image_name_odoo_db = "odoo-db"
image_tag    = "latest"


# secrets manager variables
secrets_manager_secret_name = "openems-demo-secret"


# rds variables

engine_type="postgres"
engine_type_version="16.2"
multi_az_deployment="false"
database_cluster_name="applicationdb"
master_username="openems"
master_password="openemspassword"
initial_database_name="openemsdb"
instance_class_type="db.t3.micro"