# Everything this layer needs to know about layer 1 comes from its outputs.
data "terraform_remote_state" "layer1" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.layer1_state_key
    region = var.region
  }
}