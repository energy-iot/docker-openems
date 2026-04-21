terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend configured via: terraform init -backend-config=backend.tfvars
  # See backend.tfvars.example for required values.
  backend "s3" {
    # All values provided at init time — not committed to the public repo.
  }
}
