terraform {
  backend "s3" {
    bucket         = "eiot-openems-tf-state-file"
    key            = "openems-app/terraform.tfstate"
    region         = "us-east-1"
    use_lockfile   = "true"
  }
}
