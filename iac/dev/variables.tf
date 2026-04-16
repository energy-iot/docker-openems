variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "openems"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR — chosen to not collide with existing iac/ VPC (10.0.0.0/16)"
  default     = "10.100.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.100.0.0/24"
}

variable "allowed_ips" {
  type        = list(string)
  description = "List of CIDR blocks allowed to reach the dev stack (UI, B2B, Odoo). Use /32 for single IPs."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the OpenEMS stack host"
  default     = "t3.large"
}

variable "root_volume_size_gb" {
  type    = number
  default = 40
}

variable "git_branch" {
  type        = string
  description = "docker-openems branch to check out on the instance"
  default     = "local-deployment"
}

variable "edge_count" {
  type        = number
  description = "Number of simulated edges to bootstrap"
  default     = 2
}
