# TFLint, core rules only (no provider plugin to download).
# The modules are plain folders without version blocks on purpose (see README), so the "required_version" and
# "required_providers" rules are left off; the root folders pin versions.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_required_version" {
  enabled = false
}

rule "terraform_required_providers" {
  enabled = false
}

rule "terraform_standard_module_structure" {
  enabled = false # the repo's convention is main.tf / vars.tf / outputs.tf
}

rule "terraform_naming_convention" {
  enabled = false
}

rule "terraform_documented_variables" {
  enabled = false
}

rule "terraform_documented_outputs" {
  enabled = false
}