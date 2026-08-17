# environment variables
variable "region" {
  description = "region to create resources"
  type        = string
}

variable "project_name" {
  description = "project name"
  type        = string
}

variable "environment" {
  description = "environment"
  type        = string
}


# vpc variables
variable "vpc_cidr" {
  description = "vpc cidr block"
  type        = string
}

variable "public_subnet_az1_cidr" {
  description = "public subnet az1 cidr block"
  type        = string
}

variable "public_subnet_az2_cidr" {
  description = "public subnet az2 cidr block"
  type        = string
}

variable "private_data_subnet_az1_cidr" {
  description = "private data subnet az1 cidr block"
  type        = string
}

variable "private_data_subnet_az2_cidr" {
  description = "private data subnet az2 cidr block"
  type        = string
}

# ecs variables
variable "architecture" {
  description = "ecs cpu architecture"
  type        = string
}

variable "image_name_openems_ui" {
  description = "the docker image name"
  type        = string
}

variable "image_name_openems_backend" {
  description = "the docker image name"
  type        = string
}

# variable "image_name_openems_db" {
#   description = "the docker image name"
#   type        = string
# }

variable "image_name_odoo" {
  description = "the docker image name"
  type        = string
}

# variable "image_name_odoo_db" {
#   description = "the docker image name"
#   type        = string
# }

variable "image_tag" {
  description = "the docker image tag"
  type        = string
}


#rds variables

variable "engine_type" {
  description = "engine type to run for the database"
  type        = string
}

variable "engine_type_version" {
  description = "engine type version to run for the database"
  type        = string
}

variable "multi_az_deployment" {
  description = "multi availabilty zone deployment"
  type        = bool
}

variable "database_cluster_name" {
  description = "multi availabilty zone deployment"
  type        = string
}

variable "master_username" {
  description = "master username of database cluster"
  type        = string
}

variable "initial_database_name" {
  description = "initial database name"
  type        = string
}

variable "instance_class_type" {
  description = "instance type name"
  type        = string
}


# ingress (PR-C: ALB + Route53 + ACM)

variable "domain_name" {
  description = "Public hostname for the ALB (e.g. openems.eiot.energy). Empty string = no DNS/ACM; test over the ALB's default *.elb.amazonaws.com name."
  type        = string
  default     = ""
}

variable "enable_tls" {
  description = "Turn on ACM cert + HTTPS/wss listeners. Set true only AFTER the openems.eiot.energy NS delegation is live at GoDaddy (ACM DNS validation needs it resolving publicly)."
  type        = bool
  default     = false
}