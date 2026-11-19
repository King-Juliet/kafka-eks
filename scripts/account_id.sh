#!/usr/bin/env bash
# The Argo CD files in gitops/ have to name your private registry (<account id>.dkr.ecr.<region>.amazonaws.com), and Argo CD
# cannot fill that in by itself. They ship with the placeholder ACCOUNT_ID; this script fills it in, and checks it.
#
#   bash scripts/account_id.sh set 123456789012    replace ACCOUNT_ID in gitops/ with your account id (once, then commit)
#   bash scripts/account_id.sh check               CD runs this: fails if a registry name in gitops/ is not this account's
#
# `check` needs AWS credentials (it asks which account it is signed in to). Env: AWS_REGION (default us-east-1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
HOST_PATTERN='[A-Za-z0-9_]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com'

case "${1:-}" in
  set)
    id="${2:-}"
    if ! [[ "$id" =~ ^[0-9]{12}$ ]]; then
      echo "usage: bash scripts/account_id.sh set <12-digit AWS account id>" >&2
      exit 2
    fi
    files="$(grep -rlE 'ACCOUNT_ID\.dkr\.ecr\.' "$ROOT/gitops" || true)"
    if [ -z "$files" ]; then
      echo "account_id: no ACCOUNT_ID placeholder left in gitops/ (already set?). 'check' shows which registry it names."
      exit 0
    fi
    # sed -i.bak works the same on macOS and Linux.
    while read -r file; do
      sed -i.bak "s/ACCOUNT_ID\\.dkr\\.ecr\\./${id}.dkr.ecr./g" "$file"
      rm -f "$file.bak"
    done <<<"$files"
    echo "gitops/ now names ${id}.dkr.ecr.<region>.amazonaws.com. Commit the changed files."
    ;;
  check)
    account="$(aws sts get-caller-identity --query Account --output text)"
    want="${account}.dkr.ecr.${REGION}.amazonaws.com"
    found="$(grep -rhoE "$HOST_PATTERN" "$ROOT/gitops" | sort -u || true)"
    if [ -z "$found" ]; then
      echo "account_id: no registry name found in gitops/ (expected $want); the Argo CD apps lost their ECR paths" >&2
      exit 1
    fi
    if grep -q '^ACCOUNT_ID\.' <<<"$found"; then
      echo "account_id: gitops/ still has the placeholder ACCOUNT_ID. Run: bash scripts/account_id.sh set $account  (then commit and push)" >&2
      exit 1
    fi
    if [ "$found" != "$want" ]; then
      echo "account_id: gitops/ names a registry that is not this account's." >&2
      echo "  found:    $(tr '\n' ' ' <<<"$found")" >&2
      echo "  expected: $want" >&2
      echo "  fix:      bash scripts/account_id.sh set $account  (only works while the placeholder is still there; otherwise edit the files)" >&2
      exit 1
    fi
    echo "account_id: gitops/ names $want"
    ;;
  *)
    echo "usage: bash scripts/account_id.sh set <12-digit account id> | check" >&2
    exit 2
    ;;
esac