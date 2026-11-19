#!/bin/bash
# Writes the environment file for one systemd unit. Runs as root before EVERY (re)start of the unit
# (ExecStartPre=+), so a changed Kafka password, a re-issued cluster CA or a new bootstrap address is picked
# up by simply restarting the service. Nothing secret is baked into the instance image or user-data.
#
#   render-env.sh <kafka_user> <output_file> <with_db: yes|no>
#
# Reads its settings from $ETL_ETC/config (default /etc/bitcoin-etl, written once by user-data).
# ETL_ETC and ETL_GROUP exist so tests can run this without root; production uses the defaults.
set -euo pipefail

ETC="${ETL_ETC:-/etc/bitcoin-etl}"
GROUP="${ETL_GROUP:-etl}"

KAFKA_USER="$1"
OUT="$2"
WITH_DB="$3"

# shellcheck disable=SC1091
. "$ETC/config" # REGION BOOTSTRAP_SECRET_ID DB_ENDPOINT_SECRET_ID DB_SECRET_ID CA_SECRET_ID

secret() {
  aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text
}

# systemd EnvironmentFile values must not contain whitespace, quotes, backslashes or '$'. The generated
# passwords here are alphanumeric; refuse anything else loudly instead of writing a file that parses wrongly.
safe() {
  case "$2" in
    "" | *[[:space:]\"\'\\\$]*)
      echo "render-env: value for $1 is empty or has characters an EnvironmentFile cannot hold" >&2
      exit 1
      ;;
  esac
  printf '%s' "$2"
}

BOOTSTRAP="$(safe KAFKA_BOOTSTRAP_SERVERS "$(secret "$BOOTSTRAP_SECRET_ID")")"
KAFKA_PASSWORD="$(safe KAFKA_PASSWORD "$(secret "/kafka/clients/$KAFKA_USER")")"

# The cluster CA is a public certificate; a fresh copy on every start follows CA renewals.
install -d -m 0755 "$ETC"
CA_TMP="$(mktemp "$ETC/ca.pem.XXXXXX")"
secret "$CA_SECRET_ID" > "$CA_TMP"
chmod 0644 "$CA_TMP"
mv -f "$CA_TMP" "$ETC/ca.pem"

umask 0077
TMP="$(mktemp "$ETC/env.XXXXXX")"
{
  echo "AWS_DEFAULT_REGION=$REGION"
  echo "AWS_REGION=$REGION"
  echo "KAFKA_BOOTSTRAP_SERVERS=$BOOTSTRAP"
  echo "KAFKA_SECURITY_PROTOCOL=SASL_SSL"
  echo "KAFKA_SASL_MECHANISM=SCRAM-SHA-512"
  echo "KAFKA_USERNAME=$KAFKA_USER"
  echo "KAFKA_PASSWORD=$KAFKA_PASSWORD"
  echo "KAFKA_CA_FILE=$ETC/ca.pem"
  if [ "$WITH_DB" = "yes" ]; then
    DB_JSON="$(secret "$DB_SECRET_ID")"
    DB_ENDPOINT="$(secret "$DB_ENDPOINT_SECRET_ID")"
    echo "DB_HOST=$(safe DB_HOST "$(echo "$DB_ENDPOINT" | jq -r '.host // empty')")"
    echo "DB_PORT=$(safe DB_PORT "$(echo "$DB_ENDPOINT" | jq -r '.port // empty')")"
    echo "DB_NAME=$(safe DB_NAME "$(echo "$DB_ENDPOINT" | jq -r '.name // empty')")"
    echo "DB_USER=$(safe DB_USER "$(echo "$DB_JSON" | jq -r .username)")"
    echo "DB_PASS=$(safe DB_PASS "$(echo "$DB_JSON" | jq -r .password)")"
    echo "PGSSLMODE=require"
  fi
} > "$TMP"
chgrp "$GROUP" "$TMP"
chmod 0640 "$TMP"
mv -f "$TMP" "$OUT"