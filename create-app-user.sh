#!/usr/bin/env bash
# Crea/actualiza el usuario de aplicacion (LOGIN, least-privilege) miembro de los roles writer de cada dominio.
# Uso: ./create-app-user.sh <container> <db> <superuser> <app_user> <app_pass>
set -euo pipefail
C=$1; DB=$2; SU=$3; AU=$4; AP=$5
WRITERS="iam_writer reference_writer academic_writer training_writer scheduling_writer actors_writer document_writer monitoring_writer notification_writer audit_writer"
GRANTS=$(for w in $WRITERS; do echo "GRANT $w TO $AU;"; done)
docker exec -i "$C" psql -v ON_ERROR_STOP=1 -U "$SU" -d "$DB" <<SQL
DO \$do\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$AU') THEN
    CREATE ROLE $AU LOGIN PASSWORD '$AP' INHERIT;
  ELSE
    ALTER ROLE $AU WITH LOGIN PASSWORD '$AP';
  END IF;
END \$do\$;
$GRANTS
SQL
echo "app user $AU configurado en $DB"
