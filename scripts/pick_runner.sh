#!/usr/bin/env bash
# Chooses where the in-VPC jobs run, and turns the stop-gap runner off once the permanent one works.
#
#   pick_runner.sh pick      prints  labels=<json array>  target=arc|ec2   (and appends them to $GITHUB_OUTPUT)
#   pick_runner.sh finish    scales the EC2 bootstrap runner to 0 when ARC is ready; otherwise leaves it running
#
# The Kubernetes API is private, so these jobs need a runner inside the VPC:
#   ARC  = runner pods in the cluster itself (permanent, scales to 0 when idle). Used once the secret /kafka-eks/config/arc-ready
#          is "true" (bootstrap-gitops.sh sets it after the ARC apps and their listener are up).
#   EC2  = one small instance from an Auto Scaling Group (min 0, max 1). It is what builds the cluster the first time,
#          before ARC exists. `pick` starts it when ARC is not ready.
#
# Env: MODE (auto|ec2|arc; default auto)  RUNNER_ASG (EC2 runner ASG name; needed unless MODE=arc)
#      AWS_REGION (default us-east-1)  ARC_LABEL (default kafka-eks-arc)  WAIT_SECONDS (default 900)
#      AUTH_SECRET (default /github/runner-auth: the secret holding the GitHub token the EC2 runner registers with)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
MODE="${MODE:-auto}"
ARC_LABEL="${ARC_LABEL:-kafka-eks-arc}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
AUTH_SECRET="${AUTH_SECRET:-/github/runner-auth}"
EC2_LABELS='["self-hosted","vpc-bootstrap"]'

arc_ready() {
  local v
  v="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id /kafka-eks/config/arc-ready --query SecretString --output text 2>/dev/null || true)"
  [ "$v" = "true" ]
}

token_present() { # the one manual, one-time step: has the GitHub token been put into the secret?
  aws secretsmanager get-secret-value --region "$REGION" --secret-id "$AUTH_SECRET" --query SecretString --output text 2>/dev/null |
    jq -e '(.github_token // "") != ""' >/dev/null 2>&1
}

emit() { # labels target
  echo "labels=$1"
  echo "target=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "labels=$1"
      echo "target=$2"
    } >> "$GITHUB_OUTPUT"
  fi
}

in_service() {
  aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$RUNNER_ASG" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'] | length(@)" --output text
}

cmd_pick() {
  case "$MODE" in
    auto | ec2 | arc) ;;
    *) echo "pick_runner: MODE must be auto, ec2 or arc (got '$MODE')" >&2; exit 2 ;;
  esac

  local target
  if [ "$MODE" = arc ]; then
    target=arc
    arc_ready || echo "pick_runner: WARNING MODE=arc but /kafka-eks/config/arc-ready is not 'true'; the job waits for an ARC runner" >&2
  elif [ "$MODE" = ec2 ]; then
    target=ec2
  elif arc_ready; then
    target=arc
  else
    target=ec2
  fi

  if [ "$target" = arc ]; then
    emit "\"$ARC_LABEL\"" arc
    return 0
  fi

  : "${RUNNER_ASG:?RUNNER_ASG is required to use the EC2 runner}"
  if ! token_present; then
    echo "pick_runner: $AUTH_SECRET has no github_token yet, so the EC2 runner cannot register and this run would wait forever." >&2
    echo "pick_runner: one time only: aws secretsmanager put-secret-value --secret-id $AUTH_SECRET --secret-string '{\"github_token\":\"<token>\"}'" >&2
    return 1
  fi
  echo "starting the EC2 bootstrap runner ($RUNNER_ASG)"
  aws autoscaling set-desired-capacity --region "$REGION" --auto-scaling-group-name "$RUNNER_ASG" --desired-capacity 1 --no-honor-cooldown
  local waited=0 n
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    n="$(in_service || echo 0)"
    if [ "${n:-0}" -ge 1 ]; then
      echo "instance is InService (it still has to register with GitHub; the job waits in the queue until it does)"
      emit "$EC2_LABELS" ec2
      return 0
    fi
    sleep 15
    waited=$((waited + 15))
  done
  echo "pick_runner: no InService runner instance after ${WAIT_SECONDS}s: check the ASG's scaling activity" >&2
  return 1
}

cmd_finish() {
  : "${RUNNER_ASG:?RUNNER_ASG is required}"
  if arc_ready; then
    echo "ARC is ready: scaling the EC2 bootstrap runner to 0"
    aws autoscaling set-desired-capacity --region "$REGION" --auto-scaling-group-name "$RUNNER_ASG" --desired-capacity 0 --no-honor-cooldown
  else
    echo "ARC is not ready: leaving the EC2 bootstrap runner running (the next run will use it again)"
  fi
}

case "${1:-}" in
  pick) cmd_pick ;;
  finish) cmd_finish ;;
  *) echo "usage: pick_runner.sh pick|finish" >&2; exit 2 ;;
esac