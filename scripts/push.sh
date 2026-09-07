#!/usr/bin/env bash
# Push migrations to the real map or the test map.
# Usage: scripts/push.sh prod | scripts/push.sh test
set -euo pipefail

case "${1:-}" in
  prod)
    supabase db push --yes
    ;;
  test)
    : "${ASSISTANT_TEST_DATABASE_URL:?set ASSISTANT_TEST_DATABASE_URL to the test project's pooler URI}"
    supabase db push --yes --db-url "$ASSISTANT_TEST_DATABASE_URL"
    ;;
  *)
    echo "usage: scripts/push.sh prod|test" >&2
    exit 1
    ;;
esac
