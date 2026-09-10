# Owner development

There are two development paths inside the app, plus the ordinary developer checkout
used by the owner and their coding assistants. They do not share the same authority.

| Path | Trigger | Allowed result | Stops before |
|---|---|---|---|
| Automatic Astra reviewer | New conversation evidence and scheduler eligibility | Restricted `development/` PR and inbox update | Merging, deployment, SQL execution, protected-file edits |
| Owner-requested code job | A task delegated through the assistant | `assistant/` PR, source inspection and scoped read-only database diagnostics | Merging or deploying from the background job |
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

A code job reads current source and calls `development_publish` with complete
changed files and the main revision it read. The result is a branch and pull request,
not a deployment. GitHub runs Python/database tests and builds both apps without
production credentials. `development_merge` requires both checks to pass on the
exact proposed revision. Merging starts the existing Railway deployment.

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
remain explicit. iPhone updates use `scripts/release-ios.py` on a developer Mac,
then Apple's processing and the private TestFlight group. Signing credentials stay
outside the repository. The phone does not need a cable or a running Mac to install
an uploaded release. There is no automatic GitHub-to-TestFlight build workflow yet.

See the [agent diagram](engine.md#runtime-architecture) and [release instructions](ios-release.md).
