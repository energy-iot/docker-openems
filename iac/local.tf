locals {
  # ECR registry lives in this account/region — no secret indirection needed.
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
