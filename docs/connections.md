# Data connections

The Mac app offers connection buttons in the conversation when a relevant tool needs access. Connections are optional; an unused service does not need setup. The Connections panel also lists them. All new readers return retrieval timestamps and keep pagination or truncation explicit.

| Connection | Available data | Setup |
| --- | --- | --- |
| Weather | Current estimates and forecasts | Automatic; Open-Meteo |
| Google Calendar and Gmail | Calendar events, email search and message text; create, edit and delete events and recurring series, manage guests and reminders | Google sign-in |
| Google Tasks | Task lists, outstanding and completed tasks | Separate Google permission |
| Drive, Docs and Sheets | File search, Google Docs/plain text, spreadsheet cell ranges | Separate Google read permission |
| Google Contacts | Names, contact details, organizations, birthdays | Separate Google read permission |
| Todoist | Active tasks, due dates, deadlines | Token from Integrations → Developer |
| Notion | Search page titles and read nested page blocks | Notion sign-in and page picker |
| GitHub | Repositories, source files, issues, PR changes, commits and comments | Browser sign-in |
| Supabase | Account projects, project status, schema types and deployed functions | Browser sign-in and organization approval |
| Spotify | Find music and podcast episodes; play, pause, resume, skip and seek in Spotify | Spotify sign-in; installed app for local playback |

A failed connection does not replace an existing credential. The secure setup field sends credentials only to the private desktop bridge and OS Keychain, never to Session.send, chat history, tool arguments or the memory worker. Test and production credentials occupy separate Keychain entries. Disconnect removes the local credential; revoke at the provider to invalidate it on every device. Optional Google grants use separate entries so they cannot replace Calendar/Gmail access.

Calendar and event mutations use the Calendar changes grant. Creating, renaming or deleting a secondary calendar additionally requests calendar.calendars; existing event-only connections can upgrade in chat. Event edits and deletions require a current etag; recurrence scope is explicit so a single occurrence cannot silently become a whole-series change. Guest notifications default to all; suppression must be explicitly requested.

Google scopes are `tasks.readonly`, `drive.readonly` and `contacts.readonly`. Drive read access includes spreadsheet reads. The developer Google Cloud project must enable Tasks, Drive, Sheets and People APIs; users only approve the requested Google permission. OAuth consent remains subject to the project's testing/verification settings.

Todoist still uses guided token setup. Notion uses OAuth with a page picker. GitHub and Supabase use OAuth with PKCE, expiring credentials and automatic refresh. Tokens can have wider privileges at the provider; these ordinary account tools expose read operations. Owner-development tools have separate gates. Notion uses POST for its search endpoint, which does not modify pages. No additional paid inference service is involved.

## Connection architecture

`shared/integrations.json` is the central definition of supported account connections: names, domains, setup methods and copy, API roots, verification endpoints, headers, OAuth endpoints, developer secret names, Google grants and declared capabilities. It contains no credentials. Python, the edge gateway, both apps and the registration script read it directly. Both app builds bundle the same file.

| Component | Responsibility |
| --- | --- |
| `engine/integrations/catalog.py` | Loads the shared definitions |
| `accounts.py` and `oauth.py` | Credential validation, storage, refresh and authenticated HTTP |
| `github.py`, `supabase.py`, `notion.py`, `todoist.py`, `spotify.py` | Explicit service operations and input schemas |
| `google.py`, `calendar.py`, `workspace.py` | Google authorization and service operations |
| `supabase/functions/assistant/connections.ts` | Owned sign-in intents, callbacks and encrypted cloud credentials |
| `shared/IntegrationCatalog.swift` | Shared app setup labels and authentication methods |

Implemented capabilities, configured sign-in and connected account state are separate. The gateway reports configuration from installed developer registrations; the Mac checks its Keychain. An existing credential can remain usable even when a new sign-in registration is unavailable. Capability labels describe implemented operations, not permission grants. Tools still enforce account access and scope. The separately gated owner-development tools are not ordinary connection capabilities.

To add an integration, add its public definition, implement its tool module, register it in `services.specs()`, and test input validation, missing access, denied permissions and failed reconnection. Add the credential slot to the database allowlist through a migration. Provision any developer OAuth registration outside git. A different authorization protocol needs explicit support and tests; a catalog entry alone does not implement it. The catalog supports the current Google/account OAuth and secure-token flows, not arbitrary authentication protocols.

## Limits

Spotify audio plays in Spotify. The iPhone uses Spotify's official App Remote SDK; the Mac uses Spotify's installed scripting interface. An explicit device ID can target another Spotify Connect player. The assistant checks player state before claiming success. Phone commands belong to the requesting device and active turn, expire after 100 seconds, and can be claimed once. Reconnects never replay them. Account tokens stay in the existing encrypted credential store; native iPhone authorization stays in Keychain. Starting playback ends voice capture. Spotify's account, Premium and developer-mode restrictions still apply; opening the app alone does not prove playback started.

GitHub, Supabase, Notion and Todoist are on-demand readers. Gmail is polled every two minutes and classified by a separate subscription worker, even during conversation. Failed items retry independently; classification decisions are retained, and a prolonged backlog produces one monitoring warning per incident. Reading a source does not import its entire account into memory. A cached excerpt is not current truth: tools must read again when a decision depends on current state. Search indexes can lag; pagination and nested blocks can contain more information. Google Tasks due dates are dates rather than appointment times. Notion searches titles only. Drive's text reader does not parse PDFs, images or binary attachments. GitHub comments, commits and code diffs use separate paginated reads.

On the phone, open Connections from the conversation menu. Google, GitHub, Supabase and Notion use the system sign-in sheet; Todoist uses a secure token form. Cloud credentials are encrypted with AES-GCM in private Supabase tables, bound to the owner and service, and decrypted only by the hosted worker. OAuth intents expire after ten minutes and can be redeemed once. Disconnect invalidates pending sign-ins and removes the stored credential. Mac Keychain connections remain local.

Start morning is available in the day panel and conversation menu. It starts a fresh morning session, loads the knowledge map, and fetches current calendar and email data before planning. Follow-up messages continue that session. Weather is fetched for the location in memory when relevant.

## Provider references

- [Google Tasks authorization](https://developers.google.com/workspace/tasks/auth)
- [Google Sheets read permissions](https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets.values/get)
- [Google Contacts search](https://developers.google.com/people/api/rest/v1/people/searchContacts)
- [Todoist API](https://developer.todoist.com/api/v1/)
- [Notion page content](https://developers.notion.com/guides/data-apis/working-with-page-content)
- [GitHub fine-grained token permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)


## Developer registration

For Spotify, register a Web API/iOS app with bundle ID `com.carterwatts.assistant` and these exact redirects:

- `personal-assistant://spotify`
- `https://<project>.supabase.co/functions/v1/assistant/spotify/callback`
- `http://127.0.0.1:8766/spotify/callback`

Run `python scripts/cloud.py account spotify /private/path/client.json` with `{"client_id":"..."}` from that registration. Spotify uses PKCE and requires no client secret here. Add the testing account to Spotify's developer allowlist. The shared catalog defines scopes. The iPhone's first playback request also authorizes App Remote through the installed Spotify app.

Register an OAuth app for each OAuth-based provider. End users then press Sign in. Token-based providers retain their guided secure setup.
Configure the hosted callback as `https://<project>.supabase.co/functions/v1/assistant/github/callback`
or `/supabase/callback`. The local Mac deployment also uses `http://127.0.0.1:8766/github/callback`
or `/supabase/callback`; add that explicit URI to the provider registration. Do not enable wildcard redirects.

GitHub uses `read:user repo` because OAuth apps do not offer a read-only scope for private repository contents.
The ordinary connection tools only read. Supabase needs Organizations, Projects, Database and Edge Functions **read** scopes;
it does not need Secrets or SQL execution. This connection is separate from the assistant’s own database credentials.

Run `python scripts/cloud.py account github /private/path/client.json` (or `supabase`) with a file containing
`client_id` and `client_secret`. The command stores hosted secrets in Supabase and local registration details in the
Mac Keychain. Registration secrets are not bundled into either app or committed. Additional Mac installations need
the developer registration provisioned separately in this personal deployment. Hosted phone sign-in needs no such
local configuration. Refresh tokens are encrypted on the host, and never returned to the phone or model.


## Planned per-user customization

Recorded September 8, 2026. This is upcoming architecture work, not implemented multi-user support.

The deployment currently serves one owner. Before onboarding other users, isolate memory, conversations, model sessions, credentials, background jobs, and notification delivery by authenticated account. Test that one account cannot retrieve or act on another account’s data. Shared infrastructure must not imply shared assistant context.

Separate service capabilities from user choices:

- Calendar adapters expose supported operations through a common interface. Google is the first implementation; other providers must not require rewriting the assistant’s planning behavior. Unsupported capabilities stay explicit.
- Each account selects its connected calendars and where new events or commitments belong. Multiple calendars can coexist; each external record retains its provider, account, and native ID so updates reach the correct source.
- Conversational preferences determine whether a commitment belongs in a calendar, a task service, or internal reminders. Store those choices as per-user rules and validated routing settings. Ask when the destination is ambiguous; connecting an account alone does not authorize moving existing records.
- Keep one authority for each record. Cached views and memory references point to that source rather than creating independently editable copies. Changing providers needs an explicit migration or relinking step.
- Learn morning content, reminder behavior, and other assistant preferences per user. Once resolved, code enforces routing and delivery settings; the model interprets intent within them. Credentials, access boundaries, and validation remain structural.

The current owner’s Google Calendar and separate-reminder setup is one configuration to preserve during this work, not a default to impose on everyone.

## Sign-in and discovery

On iPhone, authorization first tries the provider's verified universal link, then the system authentication sheet. The host verifies the original, single-use connection intent before accepting success. Opening an app is not proof of account access or completion of an action such as playback.

`service_discover` researches public documentation for unfamiliar services. `service_connect` offers only an implemented connection from the catalog. Discovery never registers a new integration or grants capabilities by itself. A service without an adapter needs implementation before its sign-in can be offered.

The screenshot browser experiment has been removed from the apps, gateway and worker, along with Playwright and Chromium. Applied migration history is preserved. Its old private database tables are unused and can be retired separately; no existing account credentials or memory records are migrated by this refactor.

## Email drafts

Google email sending is a separate `google_mail_send` grant. Asking for an email offers the normal connection card, then `google_mail_draft` creates a reviewable draft. The phone and Mac show From, To, Cc, Bcc, subject, and body. Changes go through a new draft revision.

The model only has prepare/read tools. The client approves through a separate authenticated endpoint with the displayed version and content hash. The database rejects stale reviews and changes to an approved draft. A deterministic sender claims each approved draft once, checks the sending account, and calls Gmail. Uncertain delivery is never automatically retried. Drafts remain assigned to the Mac or cloud host whose account prepared them.

## LinkedIn access

`linkedin_read` reads public pages when LinkedIn serves them; `linkedin_notifications` searches LinkedIn emails through connected Gmail. Shared text, exports, and screenshots can also provide context. These do not constitute live access to the personal feed, inbox, or saved posts. Standard LinkedIn sign-in only grants identity data. Its broader member portability API is restricted to eligible EU/EEA and Swiss members. See [LinkedIn API access](https://learn.microsoft.com/en-us/linkedin/shared/authentication/getting-access) and [member portability eligibility](https://www.linkedin.com/help/linkedin/answer/a6214075).

## Notion registration

Create an OAuth connection in the Notion developer portal with Read content and these exact redirects:

- `https://koauvyfxewczcajnlrfp.supabase.co/functions/v1/assistant/notion/callback`
- `http://127.0.0.1:8766/notion/callback`

Install its client ID and secret with `python scripts/cloud.py account notion /private/path/client.json`.
The registration belongs to a workspace where the developer can create connections.
Users then sign in and choose pages; they never create an internal connection or copy tokens.
Existing saved internal tokens continue working until disconnected. Notion uses HTTP Basic
client authentication and JSON token requests; its documented flow does not use PKCE.
Single-use state still binds callbacks to the owner, device and Notion intent.
Refresh tokens stay encrypted and are rotated under the existing credential lock.

[Notion OAuth authorization](https://developers.notion.com/guides/get-started/authorization)
