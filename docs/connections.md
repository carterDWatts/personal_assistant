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
| Notion | Search page titles and read nested page blocks | Internal connection with Read content; share selected pages with it |
| GitHub | Repositories, source files, issues, PR changes, commits and comments | Browser sign-in |
| Supabase | Account projects, project status, schema types and deployed functions | Browser sign-in and organization approval |

A failed connection does not replace an existing credential. The secure setup field sends credentials only to the private desktop bridge and OS Keychain, never to Session.send, chat history, tool arguments or the memory worker. Test and production credentials occupy separate Keychain entries. Disconnect removes the local credential; revoke at the provider to invalidate it on every device. Optional Google grants use separate entries so they cannot replace Calendar/Gmail access.

Calendar and event mutations use the Calendar changes grant. Creating, renaming or deleting a secondary calendar additionally requests calendar.calendars; existing event-only connections can upgrade in chat. Event edits and deletions require a current etag; recurrence scope is explicit so a single occurrence cannot silently become a whole-series change. Guest notifications default to all; suppression must be explicitly requested.

Google scopes are `tasks.readonly`, `drive.readonly` and `contacts.readonly`. Drive read access includes spreadsheet reads. The developer Google Cloud project must enable Tasks, Drive, Sheets and People APIs; users only approve the requested Google permission. OAuth consent remains subject to the project's testing/verification settings.

Notion and Todoist still use guided token setup. GitHub and Supabase use OAuth with PKCE, expiring credentials and automatic refresh. Tokens can have wider privileges at the provider, but the assistant exposes only read operations. Notion uses POST for its search endpoint, which does not modify pages. No additional paid inference service is involved.

## Limits

GitHub, Supabase, Notion and Todoist are on-demand readers. Gmail is polled every two minutes and classified by a separate subscription worker, even during conversation. Failed items retry independently; classification decisions are retained, and a prolonged backlog produces one monitoring warning per incident. Reading a source does not import its entire account into memory. A cached excerpt is not current truth: tools must read again when a decision depends on current state. Search indexes can lag; pagination and nested blocks can contain more information. Google Tasks due dates are dates rather than appointment times. Notion searches titles only. Drive's text reader does not parse PDFs, images or binary attachments. GitHub comments, commits and code diffs use separate paginated reads.

On the phone, open Connections from the conversation menu. Google, GitHub and Supabase use the system sign-in sheet; Notion and Todoist use a secure token form. Cloud credentials are encrypted with AES-GCM in private Supabase tables, bound to the owner and service, and decrypted only by the hosted worker. OAuth intents expire after ten minutes and can be redeemed once. Disconnect invalidates pending sign-ins and removes the stored credential. Mac Keychain connections remain local.

Start morning is available in the day panel and conversation menu. It starts a fresh morning session, loads the knowledge map, and fetches current calendar and email data before planning. Follow-up messages continue that session. Weather is fetched for the location in memory when relevant.

## Provider references

- [Google Tasks authorization](https://developers.google.com/workspace/tasks/auth)
- [Google Sheets read permissions](https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets.values/get)
- [Google Contacts search](https://developers.google.com/people/api/rest/v1/people/searchContacts)
- [Todoist API](https://developer.todoist.com/api/v1/)
- [Notion page content](https://developers.notion.com/guides/data-apis/working-with-page-content)
- [GitHub fine-grained token permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)


## Developer registration

Register one OAuth app per provider. End users press Sign in; they do not register developer apps or paste tokens.
Configure the hosted callback as `https://<project>.supabase.co/functions/v1/assistant/github/callback`
or `/supabase/callback`. The local Mac deployment also uses `http://127.0.0.1:8766/github/callback`
or `/supabase/callback`; add that explicit URI to the provider registration. Do not enable wildcard redirects.

GitHub uses `read:user repo` because OAuth apps do not offer a read-only scope for private repository contents.
The exposed tools only read. Supabase needs Organizations, Projects, Database and Edge Functions **read** scopes;
it does not need Secrets or SQL execution. This connection is separate from the assistant’s own database credentials.

Run `python scripts/cloud.py account github /private/path/client.json` (or `supabase`) with a file containing
`client_id` and `client_secret`. The command stores hosted secrets in Supabase and local registration details in the
Mac Keychain. Registration secrets are not bundled into either app or committed. Additional Mac installations need
the developer registration provisioned separately in this personal deployment. Hosted phone sign-in needs no such
local configuration. Refresh tokens are encrypted on the host, and never returned to the phone or model.
