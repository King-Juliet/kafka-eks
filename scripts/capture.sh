#!/usr/bin/env bash
# Runs any command and keeps what a person needs when it fails.
#
#   capture.sh <label> <command> [args...]       e.g.  capture.sh layer1-plan terraform plan -input=false -no-color
#
# Writes into $TF_ARTIFACT_DIR (default: $GITHUB_WORKSPACE/tf-artifacts, else ./tf-artifacts):
#   <label>.log           everything the command printed (stdout + stderr)
#   <label>.errors.txt    written only when the command failed: the "Error:" blocks if there are any, otherwise the
#                         last 40 lines of the log
#   <label>.tf-debug.log  the Terraform debug log, only when the caller sets TF_LOG
# The workflows upload that folder as an artifact with `if: failure()` (the "Upload logs" step at the end of each job).
#
# The exit code is the command's own. Output also goes to the job log as usual.
set -uo pipefail

label="${1:?usage: capture.sh <label> <command> [args...]}"
shift
[ "$#" -ge 1 ] || { echo "capture.sh: no command given" >&2; exit 2; }

dir="${TF_ARTIFACT_DIR:-${GITHUB_WORKSPACE:-$PWD}/tf-artifacts}"
mkdir -p "$dir"
log="$dir/$label.log"

if [ -n "${TF_LOG:-}" ]; then
  export TF_LOG_PATH="$dir/$label.tf-debug.log"
fi

printf '+ %s\n' "$*" | tee "$log"
"$@" 2>&1 | tee -a "$log"
rc="${PIPESTATUS[0]}"

if [ "$rc" -ne 0 ]; then
  errors="$dir/$label.errors.txt"
  {
    echo "$* -> exit code $rc"
    echo
    # Terraform prints errors as "Error: ..." (plain) or "│ Error: ..." (boxed); keep the block that follows.
    if ! grep -n -A 18 -E '^(│ )?Error:' "$log"; then
      echo "(no 'Error:' line; last lines of $label.log)"
      tail -n 40 "$log"
    fi
  } > "$errors"
  echo "capture: '$label' failed (exit $rc); error summary in $errors" >&2
fi
exit "$rc"