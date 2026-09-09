# Cloud worker

One Railway worker runs the subscription runtime. Supabase holds the map, owner account, requests and replayable replies. Devices need the internet, not a running Mac. This deployment serves one owner; it is not ready for unrelated customer accounts.

Railway project: `9b4aa82e-47a4-4325-9a42-b443f8cfb1a4` (`personal-assistant`). Service: `worker`. Supabase project: `koauvyfxewczcajnlrfp`.

The infrastructure definition is `.railway/railway.ts`: one replica, sleeping disabled, persistent `/data`, 2 CPUs and a 4 GiB memory ceiling. Railway charges actual resource usage; the ceiling is not a monthly spending cap. No workspace-wide cap is set because the workspace contains other applications.

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

The worker also builds from the GitHub `main` branch. Test before pushing. Database migrations remain an explicit deploy step so a code push cannot silently change the database.

`cloud.py configure` reads the database URL from the environment (or the Mac's existing literal settings) and sends it through stdin to Railway. It copies the existing ChatGPT login through the same protected path. No credentials are placed in the image or git. The container drops root privileges before starting either runtime.

## Authentication

The default worker uses Codex with forced ChatGPT authentication. There is no API-key fallback. OpenAI documents [copying the local auth cache to a headless machine](https://learn.chatgpt.com/docs/auth#fallback-authenticate-locally-and-copy-your-auth-cache).

The initial login is seeded into `/data/.codex/auth.json` with mode 0600. Later boots preserve the refreshed file rather than replacing it with the original credential. Re-running configure does not overwrite that file. Renew an expired login on the host with `CODEX_HOME="/data/Library/Application Support/Personal Assistant/prod/codex" codex login --device-auth` as the `assistant` user, or deliberately replace the host cache while the worker is stopped. Never print its contents in logs.

Claude uses `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`. Fable has been verified on the hosted subscription runtime with a live memory-database tool call. The phone can select it without changing the default runtime. Neither adapter enables paid overage.

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

The current owner chose Google Calendar as the authority for timed events and separate reminders for commitments and completion. This is an instance preference, not a product-wide requirement. Advance event notifications are a later feature. Event caches must remain disposable projections of the selected provider. Per-user provider selection and commitment routing are planned in [Data connections](connections.md#planned-per-user-customization).

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

Cross-memory attention review runs while conversation is idle, at most once per five
minutes after a changed memory snapshot, with an hourly time-based recheck. It uses
the same cheaper subscription runtime as email triage. It can flag a consequential
risk, opportunity, conflict or deadline across current facts, relationships, plans and
reminders. Every alert references current evidence, is deduplicated by category and
evidence, and shares the unsolicited notification pacing. Evidence is rechecked at
delivery. It cannot take external actions or create commitments. Coverage is limited
to available memory and connected sources; this is not a guarantee of detecting every
important development.

Voice work remains pending: smoother, cleaner speech and quicker conversational
openings. For work requiring a lookup or extended reasoning, acknowledge the user's
actual request briefly before beginning that work, explain the specific lookup, and
then continue with the result. Avoid canned acknowledgments on simple replies and
never claim a task has started before it has. Validate first-audio latency, streaming,
interruption, and complete playback together before calling the voice work finished.

Pocket TTS voice choices are Michael (default), Bill (American) and Stuart (British).
The host preloads their voice states; selection is validated against advertised IDs
and saved on the turn, so retries cannot silently change the voice. The phone keeps
its selection in Settings. Microphone mute does not cancel the model or playback.

Voice sources: Michael is VCTK p360 under CC BY 4.0, distributed by
[Kyutai](https://huggingface.co/kyutai/tts-voices). Bill Boerst and Stuart Bell are
CC0 reference recordings from [Voice-Zero](https://github.com/OwenTyme/voice-zero/blob/main/voices/README.md),
which records their LibriVox sources. These are accent options, not replicas of
Claude's proprietary voice or a specific pilot.

`web_read` reads public HTTP(S) text pages and returns source URLs, links, timestamps
and continuation offsets. It checks every redirect and pins connections to a
validated public address; no private networks, cookies or credentials are exposed.
It cannot run JavaScript, bypass access restrictions, or read binary documents.
Fetched page text is untrusted source material and is not automatically saved as memory.

## Background work and messages

The conversational runtime can call `job_start`, `jobs_list`, and `job_cancel`. Jobs are durable, tied to the requesting conversation message, and retry-safe by task key. One worker runs one job at a time, with four pending jobs at most. Each uses the selected subscription provider/model in a separate context, with a five-minute deadline and at most 60 tool calls. Child jobs cannot spawn other jobs.

Research jobs have explicit read-only memory and web/mail/calendar tools. Code jobs additionally edit an in-memory copy of the deployed assistant source, inspect database schema metadata, and retain a reviewable patch. They have no shell, credentials, external send tools, production writes, test execution, or deployment path. A completed code job means the draft is prepared; it does not mean a live fix was deployed. `jobs_list` retrieves the patch in bounded pages. Cancellation discards unfinished output; interrupted work is marked failed rather than silently replayed.

A job can send two brief progress messages, at least a minute apart. Its final message enters the inbox, with the result and patch kept separately from the model's working context. It does not automatically turn its scratch work into memory facts.

Alerts and reminder follow-ups also become assistant messages. The push is a delivery mechanism for that message. Tapping one brings an attributed copy into chat, linked to its original message ID, so a short reply carries the right context even after reconnecting or a newer reminder follow-up. Repeated delivery never duplicates the same conversation message. Existing deduplication, evidence checks and push pacing remain in place. New messages do not start audio playback or interrupt an active reply.


## Reminder delivery windows

Reminders distinguish unfinished `task` commitments from `check_in` occurrences.
Tasks remain open after their deadline and retain their follow-up schedule. A check-in
requires an end time and queues once per version, only inside its delivery window.
The dispatcher rechecks expiry before model preparation and immediately before delivery;
APNs expiry is bounded by the same window. A missed check-in is not marked completed.
Later occurrences need explicit new windows; hourly follow-up is not daily recurrence.

The reminder writer receives current local time, explicit elapsed-window flags, active
rules, and the latest 16 conversation messages from the past day. It can withhold an
occurrence when newer context makes the nudge inappropriate. Withholding does not mark
a task done. If memory or conversation changes during preparation, the dispatcher
retries with fresh context rather than sending the old draft. Semantic relevance still
requires model judgment; window enforcement and occurrence deduplication do not.


Owner development reviews use `python scripts/cloud.py development-reviews` (or
`--disable`), followed by a deployment. They run on the host’s ChatGPT subscription
with `gpt-6-astra`. New conversation excerpts trigger one bounded review after the
chat has been idle for two minutes, at least thirty minutes apart, up to four times
in a rolling day. No new messages means no model call. The durable cursor and job
keys prevent duplicate reviews after restarts. Reviews use the existing job worker,
with no child agents or shell access.

This is a private developer feature, disabled by default. The agent can inspect
chat and memory records, read scoped source, prepare a patch and publish a
`development/` branch for CI. It cannot edit prompt, identity, memory, database,
permission or development-control files. It has no merge, deployment, production
write or external-message tools. The normal merge tool rejects these branches;
the owner reviews and merges them on GitHub. CI runs without production credentials.
No-findings reviews stay quiet; actionable results enter the inbox and push pipeline.

Unsolicited messages now live in the inbox. Opening one creates an attributed
conversation entry, with an idempotent request ID. Reading the inbox does not mark
a reminder complete. Clearing chat leaves inbox items and saved knowledge intact.

Cancelling a notification reply hides only the unused chat copy. The original
message and conversation log remain intact. Once answered, the copy stays in history.
Email drafts appear beneath the reply that created them; opening the card reviews
the exact recipients and content before a separate Send confirmation.
