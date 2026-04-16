terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Reuses the existing state bucket used by iac/ — different key for isolation.
  # The bucket and lock table already exist in the AWS account.
  backend "s3" {
    bucket         = "openems-deployment-tf-state-file"
    key            = "iac/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock-openems-deployment"
    encrypt        = true
  }
}
