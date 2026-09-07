# The engine

The engine is the program that runs the conversation. It reads and writes the knowledge map directly over Postgres, hands the model a fixed set of tools over the map, mirrors every message into the map, and reports what each session cost. It is `assistant.py` plus the `engine` package.

## One conversation

There is one conversation and it never ends. Its canonical form is the message stream in the map, which every device appends to. What a model runtime calls a session is a cache of that stream on one device.

`talk` joins the conversation. If this device's last runtime session is still current, meaning nothing has been said on another device since, the runtime resumes it and the model has its full context already. If something was said elsewhere, a fresh runtime session is seeded with a snapshot of the map and the recent tail of the shared stream, and the conversation continues from there. The user sees no seam either way.

`morning` is the same conversation. It always starts a fresh runtime session, seeded the same way, adds the morning instructions to the persona, and has the assistant speak first.

The runtime's own session id is stored on the map's conversation row so a later process on the same device can resume it. Every user message, assistant message, tool call and tool result is written to the map as it happens, and each tool call records the message it was answering, so any fact can be traced to the words that produced it.

## The runtime

`engine/runtime` defines what the engine needs from a model harness: open a session with a system prompt and a list of tools, send a message and stream back events, close and report metrics. `engine/runtime/claude_agent_sdk.py` is the first implementation, on the Claude Agent SDK, which authenticates through the Claude Code login and draws from the plan's Agent SDK credit. Another vendor is one more file in that package.

The SDK implementation locks its MCP configuration to our tool server and loads no settings, because by default every request would carry the tool schemas of every connector configured in Claude Code, which measured at 36,000 tokens per turn. Locked down, an empty turn is about 500 tokens. Each session also carries a hard dollar cap.

## The tools

`engine/tools.py` defines the tools once, as plain async functions with JSON schemas, independent of any runtime: search the map, view an entity, read history, register attributes and relations, assert, retract, deprecate and confirm facts, assert and retract relationships, manage plans, rules, tuning, questions and connectors. Every write records an observation first and passes it to the map's write functions, so provenance is never optional.

## The snapshot

`engine/context.py` builds the text a fresh runtime session opens with: current facts by entity, current relationships, standing rules, yesterday's and today's plans, the best open questions and the last week's transitions. It is built from the map's views on every device identically. The richer preload and the per-turn delta belong to the hooks module.

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

`ASSISTANT_MODEL`, `ASSISTANT_EFFORT`, `ASSISTANT_SESSION_BUDGET_USD`, `ASSISTANT_DEVICE` and `ASSISTANT_TIMEZONE` override the defaults. The time zone matters: the map connection sets it so every date the database computes matches the device.

## The test map

The real map only ever holds real life. Anything exploratory runs against a separate test map: `--test` on any command, or `ASSISTANT_ENV=test`, switches the engine to `ASSISTANT_TEST_DATABASE_URL`. `scripts/testdb.sh up` provides one locally, a persistent Postgres 17 container with pgvector and every migration applied, and prints the URL to put in that variable. `reset` wipes it. `scripts/push.sh test` pushes migrations to a hosted test project instead, when there is one.

## Tests

`scripts/test.sh` runs everything against a throwaway Postgres: the migrations, the SQL checks, then the Python suite, which exercises the tools, the conversation continuity rules, the snapshot and the engine loop with a scripted runtime in place of the model.
