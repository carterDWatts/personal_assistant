# Owner development

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
