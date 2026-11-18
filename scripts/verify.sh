#!/usr/bin/env bash
# After a deploy: are the ETL services actually running, and is autoscaling getting its lag metric?
# Uses SSM Run Command (no SSH). Env: ASG_JSON (required), AWS_REGION (default us-east-1),
# LAG_GROUPS (space separated consumer group ids), TIMEOUT_SECONDS (default 900).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ASG_JSON="${ASG_JSON:?ASG_JSON is required}"
LAG_GROUPS="${LAG_GROUPS:-bitcoin_block_consumer_group bitcoin_address_consumer_group bitcoin_consumer_group}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
deadline=$(($(date +%s) + TIMEOUT_SECONDS))
failed=0

service_active() { # instance id -> 0 when bitcoin-etl.service is active
  local cmd out status
  cmd="$(aws ssm send-command --region "$REGION" --instance-ids "$1" --document-name AWS-RunShellScript \
    --parameters 'commands=["systemctl is-active bitcoin-etl.service"]' --query Command.CommandId --output text 2>/dev/null)" || return 1
  for _ in $(seq 1 15); do
    sleep 4
    status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd" --instance-id "$1" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success)
        out="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd" --instance-id "$1" --query StandardOutputContent --output text)"
        [ "$(echo "$out" | tr -d '[:space:]')" = "active" ]
        return
        ;;
      Failed | Cancelled | TimedOut) return 1 ;;
    esac
  done
  return 1
}

echo "== ETL services"
for key in $(echo "$ASG_JSON" | jq -r 'keys[]'); do
  asg="$(echo "$ASG_JSON" | jq -r --arg k "$key" '.[$k]')"
  ids="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$asg" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" --output text)"
  if [ -z "$ids" ] || [ "$ids" = "None" ]; then
    echo "$key: no InService instances" >&2
    failed=1
    continue
  fi
  for id in $ids; do
    ok=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if service_active "$id"; then
        ok=1
        break
      fi
      sleep 15
    done
    if [ "$ok" = 1 ]; then echo "$key $id: bitcoin-etl.service active"; else echo "$key $id: bitcoin-etl.service NOT active" >&2; failed=1; fi
  done
done

echo "== lag metric (autoscaling input)"
for group in $LAG_GROUPS; do
  ok=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    count="$(aws cloudwatch list-metrics --region "$REGION" --namespace KafkaEks --metric-name ConsumerLag \
      --dimensions "Name=GroupId,Value=$group" --query 'length(Metrics)' --output text)"
    if [ "${count:-0}" -ge 1 ]; then
      ok=1
      break
    fi
    sleep 20
  done
  if [ "$ok" = 1 ]; then echo "$group: ConsumerLag is being published"; else echo "$group: no ConsumerLag metric" >&2; failed=1; fi
done

exit "$failed"