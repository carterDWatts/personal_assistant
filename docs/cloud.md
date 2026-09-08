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

## Voice

The hosted voice uses Pocket TTS 3.1.0 on CPU. Model assets are cached in the image, and the voice stays loaded. Audio starts with a 320 ms packet, then streams in roughly 960 ms packets. Kokoro remains the local Mac voice. No speech API is billed.

## Planned event notifications

Google Calendar remains authoritative for timed events. Advance event notifications are a later feature; any local event cache must be disposable and reconciled with Google, not a second editable calendar. Reminders are separate commitments with their own context and completion state.

Context can be pasted through **Import context** on either app. Uploads are preserved
in `memory.imports` / `memory.import_parts`; each completed upload queues bounded
extraction jobs. Imports use system-source messages so they never appear as live
user turns or flood the pending-chat context. Live messages take priority.
Retries use the same import ID and part number; a changed replay is rejected.
The source draft remains on the device until uploaded, with a private file mode.

Current notes may update the map. Historical chats can create identities, questions
and explicitly bounded past facts; the worker rejects changes to current mandates,
plans and unbounded facts from historical imports. Unknown dates remain unknown.
`context_import_search` retrieves the original sources, including details extraction
omitted. Progress means extraction completed, not that every sentence became a fact.

Reminders live in `memory.reminders`, separately from the Google calendar. Each has
context, a time window, its next check and a follow-up interval. The acting agent
writes them in the turn; the extraction worker catches missed commitments. Only
confirmed completion or explicit cancellation closes one. Week/someday checks are
spaced; approaching deadlines shorten long intervals. Non-exact checks occur at noon
in the reminder's time zone. Snooze and edits use version checks.

The worker checks due reminders every 30 seconds and writes delivery records before
contacting APNs. Failed deliveries retry; sending never completes a reminder.
Revoked devices and obsolete reminder versions cannot receive queued alerts.
APNs credentials are Railway variables `ASSISTANT_APNS_KEY`, `ASSISTANT_APNS_KEY_ID`
and `ASSISTANT_APNS_TEAM_ID`; the key stays outside git. Enable notifications in the
phone's day panel once. Notification actions open the app, persist locally until
synced, and use the same versioned completion/snooze path as conversation tools.

Morning preparation fetches calendar/mail. Optional briefing content, including whether
to include news at all, comes from active standing preferences. No publisher or topic
is a default. Explicit preferences save inline and atomically retire replaced rules.
The NYT RSS tool remains available on request; it is not automatically called.

Background gathering scans Gmail every two minutes, with a persisted time cursor
and replay-safe source IDs. A scan advances only after all pages are saved. New
messages are triaged in batches of five by the cheaper subscription model while
conversation is idle. Empty polls use no inference. Only consequential unread mail
is eligible for an alert; unread state is checked again just before dispatch.
Sent mail can supply context but cannot trigger an alert about itself. Relevant
source material is preserved and may queue structured extraction. External sources
cannot use reminder or rule-writing tools. Failures retry with backoff.

Nightly maintenance runs once per local day after 03:00, when idle. It retires exact
duplicate active rules without deleting provenance, then makes a bounded review of
the current map for stale facts, uncertain identity matches and missing relationships.
Evidence-backed relationships and facts are recorded as inferred, with at least two
current stated/synced premises. They cannot overwrite known beliefs. Changed premises
invalidate their dependent inferences immediately. Corrected claims cannot be inferred
again without review. Uncertain changes and logical inconsistencies become linked
questions; the nightly model cannot authoritatively rewrite user statements. Direct
user corrections use memory_clarify: updates and question closure commit together.
Never-true claims are deprecated with a reason; ended states retain their validity
interval and explanation. Original observations and revision history remain auditable. Completion and errors are recorded in
`assistant.maintenance_runs`. The first deployment performs a catch-up review if
that day's scheduled time has already passed.

Notification taps carry a validated notice/reminder reference on the submitted turn.
The host retrieves its context from the database; the phone never supplies authoritative
notification content. The selected subject is visible in chat and can be dismissed.
Attention items in the day panel can also be selected for discussion. Initial mailbox
backfill does not alert. Email threads are deduplicated per day and unsolicited alerts
are spaced at least fifteen minutes apart; timed reminder delivery is separate.
Processed mail bodies are removed from the staging queue. Only source material chosen
for durable memory extraction is retained as an observation/transcript source.

`memory_archive` hides user-designated irrelevant facts and dependent inferences from
current views. It is reversible and does not mislabel them as false. A saved preference
instructs subsequent extraction and email triage to ignore similar material. Archival
is distinct from correcting false facts and from preserving genuinely expired states.
