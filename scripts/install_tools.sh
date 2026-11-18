#!/usr/bin/env bash
# Installs the command-line tools a deploy job needs and the runner image lacks, WITHOUT sudo, into
# $HOME/.local/bin (added to the job's PATH when running under GitHub Actions).
#
#   GitHub-hosted runners: everything is already there; this script only checks.
#   EC2 bootstrap runner (Amazon Linux 2023): aws, jq, python3.11 come from the image/user-data; kubectl is added here.
#   ARC runner pod (ghcr.io/actions/actions-runner): kubectl and the AWS CLI are added here. ASSUMPTION: the image
#   already has curl, jq and unzip (it is built that way upstream, but that is not verified from here).
#
# Env: KUBECTL_MINOR (default 1.37, must be within one minor of the cluster), JQ_VERSION (default 1.7.1),
#      INSTALL_DIR (default $HOME/.local/bin), NEED_KUBECTL=0 to skip kubectl.
# Verification: kubectl and jq are checked against the SHA-256 published next to the download (same origin as the
# file, so it catches corruption, not a compromised release). The AWS CLI zip is not signature-checked here.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
KUBECTL_MINOR="${KUBECTL_MINOR:-1.37}"
JQ_VERSION="${JQ_VERSION:-1.7.1}"
NEED_KUBECTL="${NEED_KUBECTL:-1}"
mkdir -p "$INSTALL_DIR"
export PATH="$INSTALL_DIR:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then echo "$INSTALL_DIR" >> "$GITHUB_PATH"; fi

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || { echo "install_tools: '$1' is required and missing from this runner image" >&2; exit 1; }; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

need curl
have git || echo "install_tools: note: git is not installed (release_clients.sh then needs RELEASE set)" >&2

if ! have jq; then
  echo "installing jq $JQ_VERSION"
  base="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}"
  curl -fsSL -o "$tmp/jq" "$base/jq-linux-amd64"
  curl -fsSL -o "$tmp/sha256sum.txt" "$base/sha256sum.txt"
  want="$(awk '$2 ~ /jq-linux-amd64$/ {print $1}' "$tmp/sha256sum.txt")"
  [ -n "$want" ] && [ "$(sha256sum "$tmp/jq" | cut -d' ' -f1)" = "$want" ] || { echo "install_tools: jq checksum mismatch" >&2; exit 1; }
  install -m 0755 "$tmp/jq" "$INSTALL_DIR/jq"
fi

if ! have aws; then
  echo "installing AWS CLI v2"
  curl -fsSL -o "$tmp/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  if have unzip; then unzip -q "$tmp/awscliv2.zip" -d "$tmp"; else python3 -m zipfile -e "$tmp/awscliv2.zip" "$tmp"; fi
  chmod -R u+rwx "$tmp/aws" 2>/dev/null || true
  "$tmp/aws/install" --install-dir "$HOME/.local/aws-cli" --bin-dir "$INSTALL_DIR" --update
fi

if [ "$NEED_KUBECTL" = 1 ] && ! have kubectl; then
  version="$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt" 2>/dev/null || true)"
  if [ -z "$version" ]; then
    echo "install_tools: no stable-${KUBECTL_MINOR}.txt; falling back to the newest stable kubectl" >&2
    version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  fi
  echo "installing kubectl $version"
  curl -fsSL -o "$tmp/kubectl" "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"
  curl -fsSL -o "$tmp/kubectl.sha256" "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl.sha256"
  [ "$(sha256sum "$tmp/kubectl" | cut -d' ' -f1)" = "$(tr -d '[:space:]' < "$tmp/kubectl.sha256")" ] ||
    { echo "install_tools: kubectl checksum mismatch" >&2; exit 1; }
  install -m 0755 "$tmp/kubectl" "$INSTALL_DIR/kubectl"
fi

echo "tools:"
for t in aws jq; do printf '  %-8s %s\n' "$t" "$("$t" --version 2>&1 | head -1)"; done
if [ "$NEED_KUBECTL" = 1 ]; then printf '  %-8s %s\n' kubectl "$(kubectl version --client 2>&1 | head -1)"; fi