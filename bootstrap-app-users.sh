#!/usr/bin/env bash
# Crea el usuario de aplicacion en las 4 instancias locales leyendo cada .env de forma segura.
set -euo pipefail
declare -A PORTS=( [develop]=15432 [qa]=15433 [staging]=15434 [main]=15435 )
for env in develop qa staging main; do
  f=".env.$env"
  db=$(grep -E '^POSTGRES_DB=' "$f" | cut -d= -f2-)
  su=$(grep -E '^POSTGRES_USER=' "$f" | cut -d= -f2-)
  au=$(grep -E '^APP_DB_USER=' "$f" | cut -d= -f2-)
  ap=$(grep -E '^APP_DB_PASSWORD=' "$f" | cut -d= -f2-)
  ./create-app-user.sh "ds-$env-postgres-1" "$db" "$su" "$au" "$ap"
done
