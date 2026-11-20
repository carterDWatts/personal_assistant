# Home server

The home deployment keeps the existing Postgres memory map, Auth, storage API and
conversation gateway. The worker uses the same subscription runtimes. There is no
new paid service. The home machine and its internet connection must stay on.

`deploy/home/compose.yaml` starts only Postgres. `api.compose.yaml` adds Auth,
PostgREST, file storage and the Deno gateway. `worker.compose.yaml` is deliberately
separate: never start it against a copied database while Railway is still running.
The two databases cannot coordinate worker leases.

## Stage

Copy the repository to the server. Keep backups and private configuration outside
git. The directory containing them should have mode 0700; private files, 0600.

```sh
cd deploy/home
python3 keys.py
# Set PUBLIC_URL in .env to the final HTTPS address.
docker compose up -d --wait db
```

Keys are generated locally and preserved on subsequent runs. Do not reuse sample
JWTs from an upstream Docker example. `.env`, `.connectors.env` and `.worker.env`
are ignored. Use a generated hexadecimal database password so URI escaping is
unambiguous.

Take a Postgres 17 custom-format dump of the hosted database with TLS certificate
verification. Supply connection details through a private environment file, not
command arguments. Preserve its SHA-256 and verify that `pg_restore --list` reads
it. Also export private storage objects and record their hashes; a database dump
contains storage metadata, not the files.

Restore into a new, empty `assistant` database. The image initializes Supabase's
roles in the cluster; the application database gets its complete schema, RLS,
functions, Auth accounts and data from the backup.

```sh
docker compose exec -T db createdb -U supabase_admin -O postgres -T template0 assistant
docker compose exec -T db pg_restore -U supabase_admin -d assistant \
  --exit-on-error --single-transaction < /private/path/source.dump
docker compose -f compose.yaml -f api.compose.yaml up -d
```

Restore errors roll back the transaction. Do not ignore errors or run migrations
over the imported data as a substitute for a verified restore. Compare row counts
and row hashes for every memory table with both connections set to UTC. Changes
made by the old worker after the snapshot require a final copy at cutover.

Postgres is bound only to `127.0.0.1:55433`, the gateway to `127.0.0.1:18080`.
Use SSH forwarding for database access. No public database port or Studio is
needed. A dedicated Tailscale Funnel HTTPS port can forward to the gateway; do
not replace other services' existing Serve/Funnel listeners.

## Finish before cutover

- Configure a working Auth sign-in transport. Email login is disabled by default;
  the local stack does not include Supabase's hosted mail delivery. Never enable
  automatic email confirmation as a workaround.
- Transfer the existing connector encryption key, OAuth registrations, APNs key
  and subscription credentials privately. Preserve the connector key exactly:
  changing it makes the imported tokens unreadable. Put gateway OAuth settings
  in `.connectors.env`, worker settings in `.worker.env`.
- Register the new provider callback addresses and configure the apps' endpoint
  and public API key. Signed-in account IDs must remain the imported owner ID.
- Restore storage objects through the storage API and verify their content hashes.
  Keep the source project if its quota prevents exporting files.
- Test sign-in, owner/device authorization, a real chat, memory extraction, voice,
  private media and notifications. An HTTP health response only proves routing.

Internal server requests use `SUPABASE_URL` / `ASSISTANT_SUPABASE_URL`.
Phone links use `SUPABASE_PUBLIC_URL` / `ASSISTANT_PUBLIC_URL`. This keeps storage
uploads and SQL RPCs on the Docker network without giving the phone container URLs.

## Cut over

Stop the old worker and prevent its automatic deployment from restarting it. Stop
the local API, take a final backup, preserve the staged database, and restore the
final copy into a fresh `assistant` database. Verify again before enabling clients.
Start the API and then the worker:

```sh
docker compose -f compose.yaml -f api.compose.yaml -f worker.compose.yaml up -d --build
```

Keep the old project and backup until the home deployment is verified. After home
accepts new writes, switching back requires copying those writes; simply restarting
Railway would fork the memory. Back up the local database, storage volume, signing
configuration and runtime credentials regularly, including an encrypted copy on
another machine.

Current staging does not change the apps or expose a public listener. Auth delivery,
credential transfer, storage export and the final worker cutover remain required.
