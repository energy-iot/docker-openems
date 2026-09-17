terraform {
  backend "s3" {
    bucket       = "eiot-openems-tfstate-383166698084"
    key          = "openems-app/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = "true"
  }
}
