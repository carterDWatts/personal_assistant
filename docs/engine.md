# The engine

The engine is the program that runs the conversation. It reads and writes the knowledge map directly over Postgres, hands the model a fixed set of tools over the map, mirrors every message into the map, and records runtime usage estimates. It is `assistant.py` plus the `engine` package.

## One conversation

There is one conversation and it never ends. Its canonical form is the message stream in the map, which every device appends to. What a model runtime calls a session is a cache of that stream on one device.

`talk` joins the conversation. If this device's last runtime session is still current, meaning nothing has been said on another device since, the runtime resumes it and the model has its full context already. If something was said elsewhere, a fresh runtime session is seeded with a snapshot of the map and the recent tail of the shared stream, and the conversation continues from there. Older messages remain searchable with `conversation_history`; the initial tail is deliberately bounded.

`morning` is the same conversation. It always starts a fresh runtime session, seeded the same way, adds the morning instructions to the persona, and has the assistant speak first.

The runtime's own session id is stored on the map's conversation row so a later process on the same device can resume it. Every user message, assistant message, tool call and tool result is written to the map as it happens, and each tool call records the message it was answering, so any fact can be traced to the words that produced it.

## The runtime

`engine/runtime` defines what the engine needs from a model harness: open a session with a system prompt and a list of tools, send a message and stream back events, close and report metrics. `engine/runtime/claude_agent_sdk.py` is the first implementation, on the Claude Agent SDK, which uses the existing Claude login and rejects API-key environment variables. Dollar values emitted by the SDK are usage estimates; they do not establish how a subscription is billed. `engine/runtime/codex.py` uses the official Codex app server with a ChatGPT subscription account. It has a separate local state directory, exposes the same map tools, and disables inherited plugins, MCP servers, shell tools and API authentication.

The SDK implementation locks its MCP configuration to our tool server and loads no settings, because by default every request would carry the tool schemas of every connector configured in Claude Code, which measured at 36,000 tokens per turn. Locked down, an empty turn is about 500 tokens. Each session also carries a hard dollar cap.

## The tools

`engine/tools.py` defines the tools once, as plain async functions with JSON schemas, independent of any runtime: search the map, view an entity, read history, register attributes and relations, assert, retract, deprecate and confirm facts, assert and retract relationships, manage plans, rules, tuning, questions and connectors. Tool inputs are validated against their JSON schemas. Each tool runs in a database transaction, so its observation and memory update succeed or roll back together. Fact writes link their source observation to the user message.

## The snapshot

`engine/context.py` builds fresh context before every turn, including resumed sessions: current facts by entity, current relationships, standing rules, yesterday's and today's plans, the best open questions and the last week's transitions. It is built from the map's views on every device identically. Facts and relationships have retrieval limits; the model can search for more. External connector synchronization and automatic extraction are not implemented yet.

## Prompts

`prompts/persona.md` is who the assistant is and how it works the map. `prompts/morning.md` is added for the morning session. They travel with the code; rules the assistant learns in conversation live in the map.

## Running it

```bash
export ASSISTANT_DATABASE_URL='postgresql://...'   # the project's session pooler URI, in your shell profile
python3 assistant.py talk
python3 assistant.py morning
python3 assistant.py snapshot
python3 assistant.py status
```

`ASSISTANT_RUNTIME`, `ASSISTANT_OPENAI_MODEL`, `ASSISTANT_MODEL`, `ASSISTANT_EFFORT`, `ASSISTANT_SESSION_BUDGET_USD`, `ASSISTANT_DEVICE` and `ASSISTANT_TIMEZONE` override the defaults. The time zone matters: the map connection sets it so every date the database computes matches the device.

## The test map

The real map only ever holds real life. Anything exploratory runs against a separate test map: `--test` on any command, or `ASSISTANT_ENV=test`, switches the engine to `ASSISTANT_TEST_DATABASE_URL`. `scripts/testdb.sh up` provides one locally, a persistent Postgres 17 container with pgvector and every migration applied, and prints the URL to put in that variable. `reset` wipes it. `scripts/push.sh test` pushes migrations to a hosted test project instead, when there is one.

## Tests

`scripts/test.sh` runs everything against a throwaway Postgres: the migrations, the SQL checks, then the Python suite, which exercises the tools, the conversation continuity rules, the snapshot and the engine loop with a scripted runtime in place of the model.

## Desktop transport

The SwiftUI app starts `python -m engine.desktop` as a child process and exchanges newline-delimited JSON over private pipes. There is no HTTP listener and no database password in the app bundle. Runtime opening, streaming, interruption and closing use the same `Session` class as the terminal. Partial replies survive failed or interrupted turns.

The native voice loop uses Speech and AVFoundation. It sends an utterance after a pause and speaks completed sentences as they stream. It stops listening during playback to avoid hearing its own voice. Stop cancels playback and asks the runtime to interrupt. Microphone permissions and real-room voice quality need to be checked on the user's Mac.
