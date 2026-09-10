# Owner development

There are two development paths inside the app, plus the ordinary developer checkout
used by the owner and their coding assistants. They do not share the same authority.

| Path | Trigger | Allowed result | Stops before |
|---|---|---|---|
| Automatic Astra reviewer | New conversation evidence and scheduler eligibility | Restricted `development/` PR and inbox update | Merging, deployment, SQL execution, protected-file edits |
| Owner-requested code job | A task delegated through the assistant | Durable workspace → `assistant/` PR → CI → eligible iPhone release | Automatic delivery of backend, prompt, memory or permission changes |
| Owner-authorized assistant tools | An explicit development request in conversation | Merge a tested `assistant/` revision; separately apply a committed migration | Unscoped repositories/projects and an untested revision |
| Developer checkout | Work directed by the owner outside the app | Local edits, tests, commits, deployment and signed releases | Governed by the operator's tools and permissions, not the hosted review restrictions |

## Automatic review

`engine/developer.py` checks once per minute when enabled. It waits for two minutes
without a new user message, enforces a 30-minute review cooldown and a maximum of
four reviews per rolling 24 hours, and yields while other background jobs are pending.
A persisted message cursor prevents the same boundary from creating duplicate jobs.
It reviews at most 60 bounded conversation excerpts plus prior review outcomes.

The shared job runner starts a fresh Codex session with `gpt-6-astra`, high effort,
a five-minute task window and a 60-tool-call budget. It can inspect selected memory
and history, read repository files and draft a patch. It has no shell, child-agent,
merge, migration or arbitrary network tool. Tests execute later in GitHub Actions.

Both workspace edits and publication reject protected paths, including prompts,
identity, memory logic, integrations, model adapters and the reviewer's own controls.
The full allow/reject logic lives in `engine/developer.py`; it is a tool-level boundary,
not a proof that arbitrary generated code is safe. Review remains necessary.

A proposed change is published on `development/`. The conversational merge tool
accepts only `assistant/` branches, so it cannot merge an automatic review PR.
The owner reviews those through the normal development workflow. A no-change result
stays quiet; findings and PRs arrive in the app inbox. Progress notes stay internal.

## Owner-requested changes

The private owner deployment can publish source changes, inspect CI, merge a tested
revision, and apply committed Supabase migrations. Ordinary installations expose
none of these tools. The host checks its configured owner against the database
owner on every operation; the repository and project are fixed host settings.

Run `python scripts/cloud.py development` once from the authenticated developer
Mac. It verifies repository administration and project access, encrypts the existing
GitHub and Supabase CLI credentials in the account store, and configures the host
scope. Tokens never enter prompts or repository files. These are personal developer
credentials, so their provider permissions remain broader than the tools exposed.
Disconnect either account to revoke the assistant's use of that connection.

A code job reads a pinned main revision through `workspace_read`, then makes exact
snippet replacements with `workspace_edit`. Reads are paginated; the complete source
stays on the host, so editing a large file cannot discard its unseen tail. The worker
saves changed files in the job record. `workspace_submit` publishes them under a
stable per-job branch. Retries recover the draft or existing PR instead of duplicating
work. A prose diff alone cannot complete an owner code job.

After submission, `engine/code_delivery.py` advances the persisted job through CI,
merge and release checks without starting another model. With
`ASSISTANT_DEVELOPMENT_AUTOSHIP=1`, owner-requested iPhone Swift changes and related
tests can ship automatically. File scope is checked again from GitHub before merge.
Both required checks must pass on the exact revision. Other changes stop at a PR
for review; disabling the flag also stops pending automatic merges. The passive
Astra review path never enters automatic delivery.

GitHub runs Python/database tests and builds both apps without production credentials.
Failures preserve the PR and report the failed stage. Completion is announced only
after the release workflow confirms that Apple made the build available to internal
TestFlight testers. It does not claim the phone has installed the update.

`development_database_read` uses Supabase's read-only query endpoint.
`development_database_migrate` only reads timestamped SQL files from current main.
It applies a new migration and records it in the Supabase migration ledger together,
with statement/lock timeouts and a migration lock. Transaction-control and COPY
statements are rejected. Destructive changes still require a specific owner request.
A migration failure rolls back; it is never reported as applied.

There is no production shell tool. The owner can authorize code deployment, but
model-written changes still need review for intent and correctness: passing tests
is evidence, not a proof that a change is safe. App changes require a new device
build; a backend deploy does not update installed phone binaries.

## Release paths

GitHub Actions runs `assistant-tests` and `assistant-apps` on PRs to main. The
assistant merge tool checks both on the supplied commit SHA. This gate applies to
that tool; it does not imply that every operator push goes through a PR.

Backend changes on main trigger the configured Railway build. Database migrations
remain explicit. Relevant changes on main trigger `release-ios.yml` on a GitHub Mac
runner: archive, sign, upload, wait for Apple, then publish a verified release receipt.
Signing credentials are repository secrets used only on main, never in PR tests.
The scripts also run on a developer Mac. The phone needs neither a cable nor a
running laptop to receive an uploaded update.

See the [agent diagram](engine.md#runtime-architecture) and [release instructions](ios-release.md).
