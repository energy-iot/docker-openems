terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State bucket and lock table provisioned by admin in the EIOT dev account.
  backend "s3" {
    bucket         = "docker-openems-feature-dev-iac"
    key            = "iac/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "docker-openems-feature-dev-iac-state-lock"
    encrypt        = true
  }
}
