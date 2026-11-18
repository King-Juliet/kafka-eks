#!/usr/bin/env bash
# Terraform with failure capture:  tf_run.sh <label> <terraform args...>   (see capture.sh for what is kept)
set -uo pipefail
label="${1:?usage: tf_run.sh <label> <terraform args...>}"
shift
[ "$#" -ge 1 ] || { echo "tf_run.sh: no terraform arguments" >&2; exit 2; }
exec bash "$(dirname "${BASH_SOURCE[0]}")/capture.sh" "$label" terraform "$@"