provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "openems"
      Environment = "aidev"
      ManagedBy   = "terraform"
      Component   = "openems-stack"
    }
  }
}
