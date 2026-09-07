# Cloud worker

One Railway worker runs the subscription runtime. Supabase holds the map, owner account, requests and replayable replies. Devices need the internet, not a running Mac. This deployment serves one owner; it is not ready for unrelated customer accounts.

Railway project: `9b4aa82e-47a4-4325-9a42-b443f8cfb1a4` (`personal-assistant`). Service: `worker`. Supabase project: `koauvyfxewczcajnlrfp`.

The infrastructure definition is `.railway/railway.ts`: one replica, sleeping disabled, persistent `/data`, 1 CPU and a 4 GiB memory ceiling. Railway charges actual resource usage; the ceiling is not a monthly spending cap. No workspace-wide cap is set because the workspace contains other applications.

## Deploy

Use a Python environment with `requirements-host.txt` installed, plus authenticated Supabase and Railway CLIs. Commands run from the repository root:

```sh
npm ci --prefix .railway
.railway/node_modules/.bin/railway link --project 9b4aa82e-47a4-4325-9a42-b443f8cfb1a4
.railway/node_modules/.bin/railway config plan
.railway/node_modules/.bin/railway config apply --yes
supabase db push --linked --dry-run --skip-vault
supabase db push --linked --skip-vault --yes
supabase functions deploy assistant --project-ref koauvyfxewczcajnlrfp --use-api
python scripts/cloud.py bind-owner cdwatts2001@gmail.com
python scripts/cloud.py configure
python scripts/cloud.py auth
.railway/node_modules/.bin/railway up --service worker --detach
```

Review the plan before applying it. It should target only personal-assistant. For a new deployment, create and link a separate Railway project before applying the same definition. Update the explicit Supabase project in the provisioning script before targeting another database. Owner binding refuses to replace an existing owner.

The worker also builds from the GitHub `design` branch. Test before pushing. Database migrations remain an explicit deploy step so a code push cannot silently change the database.

`cloud.py configure` reads the database URL from the environment (or the Mac's existing literal settings) and sends it through stdin to Railway. It copies the existing ChatGPT login through the same protected path. No credentials are placed in the image or git. The container drops root privileges before starting either runtime.

## Authentication

The default worker uses Codex with forced ChatGPT authentication. There is no API-key fallback. OpenAI documents [copying the local auth cache to a headless machine](https://learn.chatgpt.com/docs/auth#fallback-authenticate-locally-and-copy-your-auth-cache).

The initial login is seeded into `/data/.codex/auth.json` with mode 0600. Later boots preserve the refreshed file rather than replacing it with the original credential. Re-running configure does not overwrite that file. Renew an expired login on the host with `CODEX_HOME="/data/Library/Application Support/Personal Assistant/prod/codex" codex login --device-auth` as the `assistant` user, or deliberately replace the host cache while the worker is stopped. Never print its contents in logs.

Claude is packaged but requires a separately supplied `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` before switching `ASSISTANT_RUNTIME`. It has not been tested against a live Claude subscription on this host. Neither adapter enables paid overage.

Devices use Supabase email magic links with PKCE and callback `personal-assistant://auth/callback`. The verifier stays in the device Keychain; the link must be opened on that device. `cloud.py auth` allowlists this callback while preserving existing redirects and disables public signup. The default email template is retained. Devices sign in with Supabase Auth, then register their UUID through the gateway. The operator-created owner still verifies their email during sign-in. Every other account is denied access to the existing map. See [client-contract.md](client-contract.md) for the implemented transport and remaining client work.

## Operations

```sh
.railway/node_modules/.bin/railway logs --service worker --lines 50
.railway/node_modules/.bin/railway deployment list --service worker --json
.railway/node_modules/.bin/railway config plan
supabase db advisors --linked --type security --level warn
```

`Host connected.` means the worker acquired the database lease. The gateway's bootstrap reports actual host presence; a green deployment alone does not prove the worker is serving requests. Presence expires after 60 seconds. A crashed running turn ends as failed instead of repeating a possibly completed external action.

The cloud process retains its conversation runtime across messages. A separate memory loop drains durable extraction jobs without launching another Python process on each turn. Individual extraction jobs still open their own small-model sessions.

Speech stays on devices. Google credentials stored in the Mac Keychain are not yet available to the cloud worker. Shared Google OAuth, private Realtime broadcasts, remote clear/history controls remain follow-up work.

## Verification

`scripts/test.sh` runs the database migrations and Python/Swift checks against a throwaway database. `node --test tst/gateway.test.ts` checks authentication boundaries and error handling. Docker builds use an allowlist so local credentials and app bundles cannot enter the build context.

The public certificate in `deploy/supabase-ca.crt` comes from Supabase's [certificate download](https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt). It expires April 26, 2031. SHA-256: `807025ad50d4ed219d2c9c7d299c004f824eb00cf7f65afef607d07b72e6cafa`. It enables `sslmode=verify-full`; it contains no private key.
