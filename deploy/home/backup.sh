#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "$0")"
compose=(docker compose -f compose.yaml -f api.compose.yaml -f worker.compose.yaml)
root="../../backups"
mkdir -p "$root"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$root/.daily-$stamp"
mkdir "$backup"
"${compose[@]}" exec -T db pg_dump -U supabase_admin -d assistant --format=custom > "$backup/database.dump"
"${compose[@]}" exec -T db pg_restore --list < "$backup/database.dump" > "$backup/database.list"
"${compose[@]}" exec -T storage tar -C /var/lib/storage -czf - . > "$backup/objects.tar.gz"
for name in .env .auth.env .connectors.env .worker.env; do
    if [[ -f "$name" ]]; then cp "$name" "$backup/$name"; fi
done
"${compose[@]}" exec -T worker tar -C /data -czf - .codex/auth.json > "$backup/subscription.tar.gz"
(cd "$backup" && sha256sum database.dump objects.tar.gz subscription.tar.gz > SHA256SUMS)
mv "$backup" "$root/daily-$stamp"
# Only completed automatic backups expire. Migration backups are retained.
find "$root" -maxdepth 1 -type d -name 'daily-*' -mtime +7 -exec rm -rf -- {} +
echo "Backup complete: daily-$stamp"
