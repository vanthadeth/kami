#!/usr/bin/env bash
# Runs the migrations and the pgTAP tests on a throwaway plain-Postgres database.
# Needs psql, pg_prove and the pgtap extension. Connection comes from the usual PG* env vars.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
db="${TEST_DB:-kami_test}"

dropdb --if-exists "$db"
createdb "$db"
psql -q -d "$db" -c "alter database \"$db\" set search_path = \"\$user\", public, extensions"
psql -v ON_ERROR_STOP=1 -q -d "$db" -f "$here/supabase_stub.sql"
for f in "$root"/migrations/*.sql; do
  echo "migrate: $(basename "$f")"
  psql -v ON_ERROR_STOP=1 -q --single-transaction -d "$db" -f "$f" >/dev/null
done
pg_prove -d "$db" --ext .sql "$root"/tests/database/
