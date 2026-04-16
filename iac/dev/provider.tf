provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "openems"
      Environment = "dev"
      ManagedBy   = "terraform"
      Component   = "openems-stack"
    }
  }
}
