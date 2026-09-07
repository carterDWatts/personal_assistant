#!/usr/bin/env bash
# Apply every migration to a throwaway Postgres 17 (with pgvector) in Docker, then run the behavioral checks.
# Usage: scripts/test_migration.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=personal-assistant-pg-test
IMAGE=pgvector/pgvector:pg17

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=app "$IMAGE" >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 30); do
  docker exec "$NAME" pg_isready -U postgres -d app >/dev/null 2>&1 && break
  sleep 1
done

psql() { docker exec -i "$NAME" psql -U postgres -d app -v ON_ERROR_STOP=1 -q "$@"; }

# What Supabase provides out of the box and a plain image does not.
psql <<'SQL'
create schema if not exists extensions;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end $$;
SQL

for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "applying $(basename "$f")"
  psql < "$f"
done

for f in "$ROOT"/supabase/tests/*.sql; do
  echo "running $(basename "$f")"
  psql < "$f"
done
