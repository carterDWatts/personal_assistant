# Data connections

The Mac app offers connection buttons in the conversation when a relevant tool needs access. Connections are optional; an unused service does not need setup. The Connections panel also lists them. All new readers return retrieval timestamps and keep pagination or truncation explicit.

| Connection | Available data | Setup |
| --- | --- | --- |
| Weather | Current estimates and forecasts | Automatic; Open-Meteo |
| Google Calendar and Gmail | Calendar events, email search and message text; create personal calendar events | Google sign-in |
| Google Tasks | Task lists, outstanding and completed tasks | Separate Google permission |
| Drive, Docs and Sheets | File search, Google Docs/plain text, spreadsheet cell ranges | Separate Google read permission |
| Google Contacts | Names, contact details, organizations, birthdays | Separate Google read permission |
| Todoist | Active tasks, due dates, deadlines | Token from Integrations → Developer |
| Notion | Search page titles and read nested page blocks | Internal connection with Read content; share selected pages with it |
| GitHub | Search issues/PRs and read their discussion bodies | Fine-grained personal token, selected repositories, Issues and Pull requests read permissions |

A failed connection does not replace an existing credential. The secure setup field sends credentials only to the private desktop bridge and OS Keychain, never to Session.send, chat history, tool arguments or the memory worker. Test and production credentials occupy separate Keychain entries. Disconnect removes the local credential; revoke at the provider to invalidate it on every device. Optional Google grants use separate entries so they cannot replace Calendar/Gmail access.

Google scopes are `tasks.readonly`, `drive.readonly` and `contacts.readonly`. Drive read access includes spreadsheet reads. The developer Google Cloud project must enable Tasks, Drive, Sheets and People APIs; users only approve the requested Google permission. OAuth consent remains subject to the project's testing/verification settings.

The three token-based connections are guided setup, not OAuth. Tokens can have wider privileges at the provider, but the assistant exposes only read operations. Notion uses POST for its search endpoint, which does not modify pages. No additional paid inference service is involved.

## Limits

These are on-demand readers, not continuous background synchronization. Reading a source does not import its entire account into memory. A cached excerpt is not current truth: tools must read again when a decision depends on current state. Search indexes can lag; pagination and nested blocks can contain more information. Google Tasks due dates are dates rather than appointment times. Notion searches titles only. Drive's text reader does not parse PDFs, images or binary attachments. GitHub issue reads do not include comments or code diffs.

Credential setup currently runs in the Mac app. Cloud-hosted account connection and phone setup forms are still pending. A Mac Keychain connection does not authorize the Railway worker. The cloud stream identifies the missing service so clients can explain this without claiming it is connected.

## Provider references

- [Google Tasks authorization](https://developers.google.com/workspace/tasks/auth)
- [Google Sheets read permissions](https://developers.google.com/workspace/sheets/api/reference/rest/v4/spreadsheets.values/get)
- [Google Contacts search](https://developers.google.com/people/api/rest/v1/people/searchContacts)
- [Todoist API](https://developer.todoist.com/api/v1/)
- [Notion page content](https://developers.notion.com/guides/data-apis/working-with-page-content)
- [GitHub fine-grained token permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens)
