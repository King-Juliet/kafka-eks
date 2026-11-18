# The folder is named <region>-platform. Warn if the region part and var.region ever disagree.
check "region_matches_folder" {
  assert {
    condition     = basename(abspath(path.module)) == "${var.region}-platform"
    error_message = "This folder is named <region>-platform, but var.region is different. Rename the folder or fix var.region (and the region in backend.tf)."
  }
}