# Where CD uploads the ETL code (producer/, consumers/, topics/, ops/, wheelhouse/) for the ASGs to copy.
module "scripts_bucket" {
  source = "../scripts-bucket"

  bucket_name = local.scripts_bucket_name
  tags        = local.tags
}