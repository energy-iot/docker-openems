#configure aws provider to establish a secure connection between terraform and aws
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "Automation"  = "terraform"
      "Project"     = var.project_name
      "Environment" = var.environment
    }
  }
}

# Same provider, but WITHOUT default_tags. Used for ACM certificates: our SSO
# deploy role lacks acm:AddTagsToCertificate, so any tag on the cert (even a
# default one) makes RequestCertificate fail. This alias sidesteps that.
provider "aws" {
  alias  = "untagged"
  region = var.region
}
