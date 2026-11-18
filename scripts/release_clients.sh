#!/usr/bin/env bash
# Publishes the ETL code as a release and rolls the ASG instances onto it.
#   1. build   releases/<sha>/ = apps/bitcoin-etl (code) + wheelhouse (Python packages for Amazon Linux 2023)
#   2. upload  to the scripts bucket (one folder per commit; old releases stay for rollback)
#   3. point   SSM /kafka-eks/clients/release at <sha>  (instances read it when they boot)
#   4. roll    start an instance refresh on every ASG and wait for it
#
# Env: BUCKET (required), RELEASE (default: git sha), AWS_REGION (default us-east-1),
#      ASG_JSON (required): {"producer": "<asg name>", ...}; MIN_HEALTHY_JSON (optional): {"producer": 0, ...}
#      TIMEOUT_SECONDS (default 1800), DRY_RUN=1 builds only.
# Needs: python3 with pip, aws cli, jq.
set -euo pipefail

BUCKET="${BUCKET:?BUCKET is required}"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${RELEASE:-$(git -C "$ROOT" rev-parse HEAD)}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"
OUT="$ROOT/build/release"

log() { printf '\n== %s\n' "$*"; }

log "build release $RELEASE"
rm -rf "$OUT"
mkdir -p "$OUT"
# Code only: no tests, no caches, no logs.
(cd "$ROOT/apps/bitcoin-etl" && find . -type f \( -name '*.py' -o -name 'requirements.txt' \) -not -path '*/__pycache__/*' -print0 |
  while IFS= read -r -d '' file; do
    mkdir -p "$OUT/$(dirname "$file")"
    cp "$file" "$OUT/$file"
  done)
test -f "$OUT/launcher.py" -a -f "$OUT/producer/block_data_producer.py" -a -f "$OUT/consumers/block_data_consumer.py"

# Wheels for the instances (Amazon Linux 2023, x86_64, Python 3.11). --only-binary: nothing is compiled on the box.
python3 -m pip download --quiet --requirement "$OUT/requirements.txt" --dest "$OUT/wheelhouse" \
  --only-binary=:all: --implementation cp --python-version 3.11 --abi cp311 \
  --platform manylinux_2_28_x86_64 --platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64
echo "wheels: $(find "$OUT/wheelhouse" -name '*.whl' | wc -l)"
echo "$RELEASE" > "$OUT/RELEASE"

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "dry run: built $OUT, not uploading"
  exit 0
fi

log "upload to s3://$BUCKET/releases/$RELEASE/"
aws s3 sync --region "$REGION" --no-progress --delete "$OUT/" "s3://$BUCKET/releases/$RELEASE/"
aws s3api head-object --region "$REGION" --bucket "$BUCKET" --key "releases/$RELEASE/launcher.py" >/dev/null

log "move the release pointer"
aws ssm put-parameter --region "$REGION" --name /kafka-eks/clients/release --type String --value "$RELEASE" --overwrite >/dev/null

log "roll the ASGs"
ASG_JSON="${ASG_JSON:?ASG_JSON is required}"
MIN_HEALTHY_JSON="${MIN_HEALTHY_JSON:-{\}}"
for key in $(echo "$ASG_JSON" | jq -r 'keys[]'); do
  asg="$(echo "$ASG_JSON" | jq -r --arg k "$key" '.[$k]')"
  min_healthy="$(echo "$MIN_HEALTHY_JSON" | jq -r --arg k "$key" '.[$k] // 50')"

  # An earlier refresh may still be running (for example the instances' first boot); replace it.
  running="$(aws autoscaling describe-instance-refreshes --region "$REGION" --auto-scaling-group-name "$asg" \
    --query "InstanceRefreshes[?Status=='Pending'||Status=='InProgress'||Status=='Cancelling'].InstanceRefreshId" --output text)"
  if [ -n "$running" ] && [ "$running" != "None" ]; then
    echo "$asg: cancelling refresh $running"
    aws autoscaling cancel-instance-refresh --region "$REGION" --auto-scaling-group-name "$asg" >/dev/null || true
    for _ in $(seq 1 30); do
      left="$(aws autoscaling describe-instance-refreshes --region "$REGION" --auto-scaling-group-name "$asg" \
        --query "InstanceRefreshes[?Status=='Pending'||Status=='InProgress'||Status=='Cancelling'].InstanceRefreshId" --output text)"
      { [ -z "$left" ] || [ "$left" = "None" ]; } && break
      sleep 10
    done
  fi

  id="$(aws autoscaling start-instance-refresh --region "$REGION" --auto-scaling-group-name "$asg" \
    --preferences "{\"MinHealthyPercentage\": ${min_healthy}, \"InstanceWarmup\": 120}" \
    --query InstanceRefreshId --output text)"
  echo "$asg: started refresh $id (min healthy ${min_healthy}%)"
  echo "$key=$id" >> "$OUT/../refreshes.txt"
done

log "wait for the refreshes"
deadline=$(($(date +%s) + TIMEOUT_SECONDS))
failed=0
while read -r line; do
  key="${line%%=*}"
  id="${line#*=}"
  asg="$(echo "$ASG_JSON" | jq -r --arg k "$key" '.[$k]')"
  while true; do
    status="$(aws autoscaling describe-instance-refreshes --region "$REGION" --auto-scaling-group-name "$asg" \
      --instance-refresh-ids "$id" --query 'InstanceRefreshes[0].Status' --output text)"
    case "$status" in
      Successful)
        echo "$asg: Successful"
        break
        ;;
      Failed | Cancelled | RollbackSuccessful | RollbackFailed)
        echo "$asg: $status" >&2
        failed=1
        break
        ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "$asg: still $status after ${TIMEOUT_SECONDS}s" >&2
      failed=1
      break
    fi
    sleep 20
  done
done < "$OUT/../refreshes.txt"
rm -f "$OUT/../refreshes.txt"
exit "$failed"