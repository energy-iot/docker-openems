terraform {
  backend "s3" {
    bucket         = "openems-tf-state-file"
    key            = "openems-app/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock-openems"
  }
}
