# Client contract

Status: initial relay implemented; client integration is next. This contract covers Carter's personal assistant across authenticated devices. It does not establish support for customer subscription billing.

## Responsibilities

Supabase handles identity, durable commands, conversation events, memory and private change notifications. A separately provisioned worker runs the subscription runtime and connects outward to Supabase. The phone does not require an inbound connection to the worker. A Mac can run the worker during development; a separate always-on host is required for Mac-off operation. The cloud worker runs on Railway with a persistent volume.

Clients handle presentation and local speech. Model credentials stay on the worker. No database administrator credentials reach a client. No paid model fallback is permitted.

## Identity

Use Supabase Auth, initially restricted to the owner's account. Each registered device belongs to an authenticated user. Server operations derive user identity from verified authentication, never from submitted user IDs. Check device revocation and ownership on each operation. Database policies and cross-owner references must enforce isolation before client access is enabled.

Worker credentials are separately provisioned. This deployment has exactly one allowlisted owner; its worker has access to that owner's whole database. This is not a multi-tenant authorization scheme. Owning a client session does not grant worker privileges. Exact sign-in and worker provisioning flows remain implementation decisions; no custom permanent device bearer token is assumed.

## Client operations

These are logical method names; see the concrete transport below. The currently implemented operations below use the authenticated Edge Function; the remaining operations are follow-up work.

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

Private Realtime is the intended wake-up transport, not the only record. The first gateway supports HTTP replay; Realtime authorization and broadcasts are not deployed yet. Until then, poll while foregrounded (250 ms during a reply; back off when idle) and stop polling in the background. When Realtime is enabled, subscribe and wait for readiness, then replay from the last applied cursor. Re-authorize the channel when the JWT refreshes. Fetch again on notifications and after reconnect; deduplicate already applied events. Paginate until caught up. Cursor expiry requires a fresh history snapshot and explicit reset response.

Backgrounding may close the iOS connection. On foreground, refresh authentication, subscribe and catch up. Replayed text must not automatically speak old replies. Store the cursor and pending drafts with platform data protection; tokens belong in Keychain.

On interruption, stop local playback immediately and cancel by turn ID. Late events can update durable history but must not restart playback for that turn. Capture the next utterance locally while waiting for the prior turn to stop. A cancellation acknowledgment does not undo an external action already completed.

Workers use a 60-second lease and a unique worker ID to prevent stale workers from publishing results. A restart after an uncertain external action requires reconciliation using action receipts, not blind replay. Host availability is explicit; offline workers cannot process requests simply because Supabase is reachable.

## Connections

A missing permission produces an in-chat connection action. Google, GitHub and Supabase use hosted authorization; connecting an account on the local Mac does not automatically authorize the cloud worker. Supported providers and setup methods come from `shared/integrations.json`. The client opens the supplied authorization URL in a system browser session. Google requires a registered host web OAuth flow; the existing desktop localhost callback is not a phone callback.

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

## Initial HTTP transport

POST `https://koauvyfxewczcajnlrfp.supabase.co/functions/v1/assistant` with `Authorization: Bearer <Supabase user access token>`, the project's public `apikey`, and JSON:

```json
{"action":"submit","device_id":"<device UUID>","args":{"client_message_id":"<message UUID>","text":"Hello"}}
```

The gateway verifies the user with Supabase Auth. Never call `assistant_client` from a client: that RPC is restricted to the gateway's service role. Never put the service key or a database URL in a client.

| action | args | result |
| --- | --- | --- |
| register | name | device_id |
| bootstrap | none | conversation_id, history, cursor, replay_after, host {online, seen_at}, active_turn, day, identity |
| submit | client_message_id, text, optional model (catalog id), speech (boolean) | turn_id, status |
| events | after (cursor, initially 0) | events, has_more |
| cancel | turn_id | status (cancellation_requested is not completion) |
| clear | optional request_id (UUID, reuse on retry) | status cleared, cutoff |
| revoke | device_id | revoked |

On bootstrap, show history and replay from `replay_after`, which may be earlier than `cursor` when a reply is in progress. This reconstructs the active reply's prefix. Subsequent polls use the last applied cursor. Replies have one stable conversation_id across runtime restarts. Persisted `delta` uses `text`; `replace` also uses `text`. Timestamps use `created_at`.

A successful submit can be queued while the host is offline. Preserve the draft until its UUID is accepted. HTTP 409 returns conversation_busy or idempotency_conflict; 403 returns account_denied or device_denied; 401 requires sign-in. 503 is a temporary service failure and reveals no internal error.

The owner account is provisioned by an operator, and email verification occurs during sign-in. New accounts cannot claim the existing map. Host presence expires after 60 seconds, renewed every 20 seconds. A terminal failed event after restart requires checking external action results before retrying.

The `day` object has day, learned, plans, questions, pending and errors. The worker publishes `map` and `memory` events after extraction changes and at day rollover. `identity` comes from root identity.json.

Clear refuses queued or running turns with conversation_busy. It writes a chat_cleared marker, preserves stored history and structured memory, and broadcasts history with empty messages to other clients. The next cloud reply opens a fresh runtime. Repeated no-argument calls before new activity are idempotent; use a stable request_id to make delayed retries safe even after new messages arrive.

Paginated older history, reminder delivery, host Google authorization and Realtime subscriptions are not implemented in this transport yet. The existing Mac bridge remains usable independently.

`tst/fixtures/relay.jsonl` contains event envelopes for a completed and cancelled turn and a separate HTTP busy response. Speech is not exercised by this fixture.

Host capabilities include `models` (id, name, runtime, model) discovered from the signed-in subscription harness and `speech`. A model is selected per turn, rejected if absent from that catalog, and is part of the retry identity. Switching opens the appropriate runtime against the same memory and conversation history. Claude choices appear only when the host has its subscription token.

Voice submits opt into speech. The host uses the voice in identity.json, preloads it before advertising speech, and emits `speech` (seq, text, duration_ms, signed URL) plus `speech_end` (success/error). Audio is generated concurrently with text; `end` still completes text and may precede speech_end. Clients play only their own voice-submitted turns, dedupe by turn_id/seq, and suppress bootstrap recovery audio. Keep polling until speech_end. Cancel remains valid after text end and stops later speech publication. New turns stop prior synthesis. Audio download and playback must stop immediately on interruption, independently of network cancellation. Speech failures preserve the text.

Audio lives in a private speech bucket, signed for ten minutes, and is deleted after one day by the worker (hourly cleanup). Upload tracking lives in assistant.speech_objects, never in the knowledge map. Provision with `python scripts/cloud.py speech`; no storage credentials belong in clients.

### Messages initiated by the assistant

`proactive` events contain a `message` row (`id`, `role`, `content`, `created_at`, `payload`). Render it as an assistant chat message, deduplicated by database ID, without taking ownership of the active streamed reply or playing audio. Bootstrap history includes the same payload. `payload.reference` links a notice or reminder.

Notification replies send `notification: {kind, id, message_id?}`. `notification_message` accepts that reference and returns the persisted message, including older messages outside the bootstrap tail. The gateway verifies owner and device; submit validates that the message belongs to that reference. After sending, clear the reply selection; the response and future conversation preserve the discussion naturally.

## Draft review and images

`email` is an authenticated client action with `operation: list | get | approve | discard`. Approval requires the draft `id`, `version`, and `content_hash` shown by the client. None of these client operations is a model tool. An `email_draft` event opens the review sheet; the draft list also survives reconnects.

`image` supports `upload` and `get`. Upload accepts a client UUID, filename, MIME type, and base64 image data (4 MB maximum). It returns an image ID; get returns a short-lived signed URL after ownership checks. The private `chat-images` bucket is provisioned with `python3 scripts/cloud.py images`. Mac bridge credentials live in Keychain. Never store signed URLs or image bytes in transcript text.

`submit` accepts up to four `images` IDs from the same account. Request retries must preserve these IDs. The host records image IDs in the user message payload and emits `images_saved` after persistence. The adapters provide image content to the model. `image_show` emits an `image` event and preserves the ID on the assistant message; `image_read` retrieves saved visual context on demand. Image output currently shares existing or public images; it does not add a paid image-generation service.
