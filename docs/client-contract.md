# Client contract

Status: backend proposal, not deployed. Fable's review is pending. This contract covers Carter's personal assistant across authenticated devices. It does not establish support for customer subscription billing.

## Responsibilities

Supabase handles identity, durable commands, conversation events, memory and private change notifications. A separately provisioned worker runs the subscription runtime and connects outward to Supabase. The phone does not require an inbound connection to the worker. A Mac can run the worker during development; a separate always-on host is required for Mac-off operation. Hardware is not selected.

Clients handle presentation and local speech. Model credentials stay on the worker. No database administrator credentials reach a client. No paid model fallback is permitted.

## Identity

Use Supabase Auth, initially restricted to the owner's account. Each registered device belongs to an authenticated user. Server operations derive user identity from verified authentication, never from submitted user IDs. Check device revocation and ownership on each operation. Database policies and cross-owner references must enforce isolation before client access is enabled.

Worker credentials are separately provisioned and owner-scoped. Owning a client session does not grant worker privileges. Exact sign-in and worker provisioning flows remain implementation decisions; no custom permanent device bearer token is assumed.

## Client operations

These are logical method names, not existing endpoints. Exact RPC names, schemas and fixtures must be committed before live client integration.

| Operation | Behavior |
| --- | --- |
| register_device | Register a random device UUID under the authenticated account. |
| bootstrap | Return identity, active conversation, host state, connection capabilities and day panel. |
| submit_message | Persist and accept one message using a client-generated UUID; return its turn ID. |
| cancel_turn | Record cancellation intent for a specific turn; distinguish acceptance from completion. |
| get_events | Replay ordered events after a conversation cursor, with pagination. |
| get_history | Page older conversation messages. |
| get_day | Read plans, questions and memory progress. |
| clear | Start a fresh runtime segment while preserving structured memory and archived history. |
| request_connection | Begin an owner-bound integration authorization intent. |

A repeated message UUID with identical input returns the existing result. Reusing it with changed input fails. One turn runs per conversation; another device receives a busy result rather than silently queuing a stale request. A client retains its unsent draft and original UUID for retry.

## Events

Preserve the Mac bridge payload vocabulary: `history`, `ready`, `start`, `delta`, `replace`, `end`, `memory`, `map`, `status`, `error`, `connection_required`, `connections`.

Remote delivery wraps each payload in an envelope containing `version`, `event_id`, `conversation_id`, nullable `turn_id`, `cursor`, `created_at`, and `payload`. Version starts at 1. The existing payload's `type` identifies its event. This envelope is new; the local bridge remains unchanged until an adapter exists.

`replace` contains authoritative text and replaces accumulated deltas. Remote `end` additionally identifies completion as completed, cancelled or failed. `ready` means the conversation can accept another turn. Raw tool inputs, hidden reasoning, credentials and raw exception dumps are never client events.

Cursors are assigned in conversation commit order under serialization. A global sequence alone cannot guarantee replay order. Batch text deltas rather than writing a row for each token; target roughly 100–200 ms flushes initially, then measure voice latency and quota consumption. Persist before notifying.

## Reconnect and interruption

Private Realtime is a wake-up signal, not the only record. Subscribe and wait for readiness, then replay from the last applied cursor. Fetch again on notifications and after reconnect; deduplicate already applied events. Paginate until caught up. Cursor expiry requires a fresh history snapshot and explicit reset response.

Backgrounding may close the iOS connection. On foreground, refresh authentication, subscribe and catch up. Replayed text must not automatically speak old replies. Store the cursor and pending drafts with platform data protection; tokens belong in Keychain.

On interruption, stop local playback immediately and cancel by turn ID. Late events can update durable history but must not restart playback for that turn. Capture the next utterance locally while waiting for the prior turn to stop. A cancellation acknowledgment does not undo an external action already completed.

Workers use a lease and fencing generation to prevent stale workers from publishing results. A restart after an uncertain external action requires reconciliation using action receipts, not blind replay. Host availability is explicit; offline workers cannot process requests simply because Supabase is reachable.

## Connections

A missing permission produces an in-chat connection action. The client opens the supplied authorization URL in a system browser session. Google requires a registered host web OAuth flow; the existing desktop localhost callback is not a phone callback.

Authorization intents are short-lived, single-use and bound to the owner and initiating device. Validate state and PKCE. Verify completion from the authenticated service rather than trusting a deep link. Token exchange and encrypted credential storage are server-owned. A callback returns no Google token to the phone. Device sign-out and disconnecting the shared Google account are separate operations.

## Voice and reminders

Speech recognition and synthesis run on the client initially; only finalized utterance text reaches the engine. Partial dictation stays local. No audio transport is required by version 1.

A background socket is not reminder delivery. Already synchronized reminders may be scheduled locally. Remote updates require an APNs adapter and provisioning; this remains separate from typed-chat readiness.

## Acceptance checks

- Two devices share history without duplicate sends or mixed ownership.
- Lost notifications, disconnects and duplicate events recover without missing text.
- Interrupted replies never resume playback; completed external actions are not repeated.
- Revoked devices cannot send, read or subscribe.
- Connection cancellation, expiry and permission upgrades are visible in chat.
- The phone works with the Mac off when the independent worker is available.
- Subscription limits stop work with a clear state and no paid fallback.

## Evidence

Supabase hosted Edge Functions have 256 MB memory and bounded execution lifetimes, so this design places the native subscription harness on a separate worker: https://supabase.com/docs/guides/functions/limits .

Anthropic's current pause notice says SDK usage still draws from subscription limits: https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan . Headless subscription token authentication is documented at https://code.claude.com/docs/en/authentication . This is not a promise that those policies will remain unchanged.
