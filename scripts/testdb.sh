#!/usr/bin/env bash
# A persistent local test map: Postgres 17 with pgvector in Docker, migrations applied.
# Usage: scripts/testdb.sh up | down | reset | url
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=personal-assistant-testdb
IMAGE=pgvector/pgvector:pg17
PORT=55433
URL="postgresql://postgres:test@localhost:$PORT/app"

psql() { docker exec -i "$NAME" psql -U postgres -d app -v ON_ERROR_STOP=1 -q "$@"; }

migrate() {
  for _ in $(seq 1 30); do
    docker exec "$NAME" pg_isready -U postgres -d app >/dev/null 2>&1 && break
    sleep 1
  done
  psql <<'SQL'
create schema if not exists extensions;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end $$;
create table if not exists public.applied_migrations (name text primary key, applied_at timestamptz not null default now());
SQL
  for f in "$ROOT"/supabase/migrations/*.sql; do
    n="$(basename "$f")"
    if [ "$(psql -tA -c "select count(*) from public.applied_migrations where name = '$n'")" = "0" ]; then
      echo "applying $n"
      psql < "$f"
      psql -c "insert into public.applied_migrations (name) values ('$n')"
    fi
  done
}

case "${1:-}" in
  up)
    if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
        docker start "$NAME" >/dev/null
      else
        docker run -d --name "$NAME" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=app -p "127.0.0.1:$PORT:5432" \
          -v "$NAME-data:/var/lib/postgresql/data" "$IMAGE" >/dev/null
      fi
    fi
    migrate
    echo "test map ready: $URL"
    ;;
  down)
    docker stop "$NAME" >/dev/null 2>&1 || true
    echo "test map stopped (data kept)"
    ;;
  reset)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$NAME-data" >/dev/null 2>&1 || true
    "$0" up
    ;;
  url)
    echo "$URL"
    ;;
  *)
    echo "usage: scripts/testdb.sh up|down|reset|url" >&2
    exit 1
    ;;
esac
