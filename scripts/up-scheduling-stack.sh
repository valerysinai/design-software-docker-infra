#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"
LOCAL_TRAEFIK="${LOCAL_TRAEFIK:-false}"

read_required_env() {
  local name="$1"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE" >&2
    exit 1
  fi
  local value
  value="$(grep -E "^[[:space:]]*${name}=" "$ENV_FILE" | head -n1 | sed -E "s/^[[:space:]]*${name}=//" | sed -E 's/^\"|\"$//g' || true)"
  if [[ -z "$value" ]]; then
    echo "$name is required in $ENV_FILE" >&2
    exit 1
  fi
  printf '%s' "$value"
}

assert_sql_identifier() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "$name must be a safe SQL identifier" >&2
    exit 1
  fi
}

db="$(read_required_env POSTGRES_DB)"
su="$(read_required_env POSTGRES_USER)"
app_user="$(read_required_env APP_DB_USER)"
app_pass="$(read_required_env APP_DB_PASSWORD)"
assert_sql_identifier POSTGRES_DB "$db"
assert_sql_identifier POSTGRES_USER "$su"
assert_sql_identifier APP_DB_USER "$app_user"

compose_files=(-f docker-compose.yml)
if [[ "$LOCAL_TRAEFIK" == "true" ]]; then
  compose_files+=(-f docker-compose.traefik-local.yml)
fi

compose=(docker compose --env-file "$ENV_FILE" "${compose_files[@]}")
profiles=(--profile scheduling --profile observability --profile edge --profile tooling)

echo "Starting base services..."
"${compose[@]}" "${profiles[@]}" up -d postgres rabbitmq otel-collector tempo traefik

echo "Applying IAM schema..."
"${compose[@]}" "${profiles[@]}" run --rm liquibase-iam update

echo "Applying Scheduling schema..."
"${compose[@]}" "${profiles[@]}" run --rm liquibase-scheduling update

escaped_pass="${app_pass//\'/\'\'}"

echo "Configuring least-privilege application database role..."
cat <<SQL | "${compose[@]}" "${profiles[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U "$su" -d "$db"
DO \$do\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$app_user') THEN
    CREATE ROLE $app_user LOGIN PASSWORD '$escaped_pass' INHERIT;
  ELSE
    ALTER ROLE $app_user WITH LOGIN PASSWORD '$escaped_pass';
  END IF;
END \$do\$;
GRANT iam_writer TO $app_user;
GRANT scheduling_writer TO $app_user;
SQL

echo "Starting IAM, Scheduling and observability services..."
"${compose[@]}" "${profiles[@]}" up -d iam-api scheduling-api prometheus loki grafana

echo "Scheduling stack is running."
"${compose[@]}" "${profiles[@]}" ps
