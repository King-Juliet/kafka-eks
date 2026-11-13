# This folder is named after its AWS region. Warn if the folder and var.region ever disagree.
check "region_matches_folder" {
  assert {
    condition     = basename(abspath(path.module)) == var.region
    error_message = "This folder is named after its region, but var.region is different. Rename the folder or fix var.region (and the region in backend.tf)."
  }
}