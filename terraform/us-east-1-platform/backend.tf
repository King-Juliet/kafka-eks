# Own state file, separate from ../us-east-1: this layer runs on a runner inside the VPC, layer 1 does not.
# Same bucket and region as layer 1; only the key differs.
terraform {
  backend "s3" {
    bucket       = "juliet-terraform-state"
    key          = "eks-kafka/us-east-1-platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}