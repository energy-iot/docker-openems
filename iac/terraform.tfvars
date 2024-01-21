# environment variables
region       = "us-east-1"
project_name = "openems"
environment  = "demo"

# vpc variables
vpc_cidr                     = "10.0.0.0/16"
public_subnet_az1_cidr       = "10.0.0.0/24"
public_subnet_az2_cidr       = "10.0.1.0/24"

# s3 variables
env_file_bucket_name = "openems-terraform-env-file"
env_file_name        = "env-variables-file.env"

# ecs variables
architecture = "X86_64"
image_name_openems_ui = "openems-ui"
image_name_openems_backend = "openems-backend"
image_name_openems_db = "openems-db"
image_name_odoo = "odoo"
image_name_odoo_db = "odoo-db"
image_tag    = "latest"


# secrets manager variables
secrets_manager_secret_name = "openems-demo-secret"