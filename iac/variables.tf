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

variable "image_name_openems_db" {
  description = "the docker image name"
  type        = string
}

variable "image_name_odoo" {
  description = "the docker image name"
  type        = string
}

variable "image_name_odoo_db" {
  description = "the docker image name"
  type        = string
}

variable "image_tag" {
  description = "the docker image tag"
  type        = string
}


# secrets manager variables
variable "secrets_manager_secret_name" {
  description = "the secrets manager secret name"
  type        = string
}