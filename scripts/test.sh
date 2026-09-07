#!/usr/bin/env bash
# The whole test suite against a throwaway Postgres 17 with pgvector in Docker:
# every migration, the SQL behavioral checks, then the Python tests.
# Usage: scripts/test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=personal-assistant-pg-test
IMAGE=pgvector/pgvector:pg17
PORT=55432

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=test -e POSTGRES_DB=app -p "127.0.0.1:$PORT:5432" "$IMAGE" >/dev/null
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
  psql -1 < "$f"
done

for f in "$ROOT"/supabase/tests/*.sql; do
  echo "running $(basename "$f")"
  psql -1 < "$f"
done

echo "running python tests"
cd "$ROOT"
ASSISTANT_TEST_DATABASE_URL="postgresql://postgres:test@localhost:$PORT/app" "${PYTHON:-python3}" -m pytest -q "$@"

if [[ "$(uname)" == Darwin ]] && command -v swiftc >/dev/null; then
  mkdir -p "$ROOT/build"
  swiftc -parse-as-library "$ROOT/desktop/OutputStream.swift" "$ROOT/tst/swift/OutputStreamCheck.swift" -o "$ROOT/build/stream-check"
  "$ROOT/build/stream-check"
fi
