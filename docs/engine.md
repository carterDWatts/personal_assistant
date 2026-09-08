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

## Background memory

The conversational model receives only read tools. A database trigger queues each user message durably; after the reply, a detached worker extracts structured updates using the same subscription provider. ChatGPT extraction defaults to `gpt-5.4-mini`; Claude extraction defaults to `haiku`. `ASSISTANT_MEMORY_OPENAI_MODEL` and `ASSISTANT_MEMORY_CLAUDE_MODEL` override these choices.

The worker submits one batch using the existing memory operations. The batch and queue completion commit in one transaction, so retries cannot partially save or duplicate a completed update. A database advisory lock serializes workers, and messages are processed in order. Mutable properties become assertions, with provenance linked to the source message.

Queued work survives closing the app. Failed work remains queued for a later app launch or turn, with a five-minute retry delay; there is no always-running retry scheduler. Memory progress appears separately from reply progress and never disables the composer. `prompts/memory.md` defines extraction behavior.

## The snapshot

`engine/context.py` builds fresh context before every turn, including resumed sessions: current facts by entity, current relationships, standing rules, yesterday's and today's plans, the best open questions and the last week's transitions. It is built from the map's views on every device identically. Facts and relationships have retrieval limits; the model can search for more. Recent user statements awaiting extraction are included directly, so replies can use them immediately. External connector synchronization is not implemented yet.

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

The SwiftUI app starts `python -m engine.desktop` as a child process and exchanges newline-delimited JSON over private pipes. There is no HTTP listener and no database password in the app bundle. Every few seconds the bridge also sends a `map` event with the latest facts learned, today's plan, the count of open questions and the memory queue state, which the app uses for its day panel. Runtime opening, streaming, interruption and closing use the same `Session` class as the terminal. Partial replies survive failed or interrupted turns.

The native audio loop uses AVFoundation. `LiveVoice` keeps capture running during playback, with Apple voice processing enabled for echo cancellation and automatic recovery after audio configuration changes. It sends bounded PCM frames to `engine.voice.recognize` over a private pipe. That process runs sherpa-onnx locally and emits partial and final transcripts. It has no database access, model credentials or network dependency. Partial text appears in a fixed panel below the chat, without moving the conversation. The same Python module can run on Linux; sherpa's C API supports mobile integrations, which are not implemented here yet.

Recognized speech cancels synthesis, queued playback and model generation. Completed utterances wait for the previous model turn to end. `engine.voice.synthesize` keeps Kokoro loaded in a separate local process and streams sentence audio through a private pipe. The selected voice is British George (speaker 26). Cancellation invalidates queued synthesis and stops playback immediately; late audio is discarded by request ID. Both speech processes run without database or model-provider credentials. Physical speaker/microphone echo testing remains outstanding.

To verify retrieval with a real subscription model, run `python3 -m scripts.check_memory`. This creates a random fact in a rolled-back transaction on the local test map. A fresh ChatGPT session gets no transcript or snapshot and must recover the value through map tools. The check leaves existing chats and facts unchanged.

Clear starts a fresh agent and resets the visible conversation in the selected memory environment. The boundary persists across restarts and model changes. Structured facts and queued extraction remain intact; older messages remain stored for provenance and explicit history searches but are excluded from the conversation seed and pending-message context.

## Voice verification

Run `python3 -m engine.voice.models` once, then `python3 -m scripts.check_voice`. The check streams two public model-test recordings in 20 ms chunks through the actual recognition subprocess. It checks silence, partial text before the recording ends, final text accuracy, and consecutive utterances. It never writes to the knowledge map or calls an LLM. Fixtures and model weights live outside the repository under `~/.personal-assistant/models`; model revision and ONNX checksums are pinned. `ASSISTANT_SPEECH_MODEL` overrides the directory.

Unit tests cover malformed audio framing and interruption state. Those tests do not establish acoustic echo rejection, microphone selection, expressive voice quality, or Pi performance.

## Independent devices

Every device is intended to run its own engine, connected directly to shared memory and the model provider. No Mac relay is part of this design. The voice library supports Mac, Linux, Android and iOS, but only the Mac integration is currently implemented and tested. There is no additional speech API bill.

The model harness is a separate unresolved constraint: [Claude Code documents 4 GB RAM and desktop operating systems](https://code.claude.com/docs/en/setup), while the [Pi 3 Model B has 1 GB RAM](https://www.raspberrypi.com/products/raspberry-pi-3-model-b/). Independent subscription access from a mobile app has not been established. These requirements must be solved explicitly before claiming either device is deployable.

Speech dependencies: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and the [Apache-2.0 English model](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26). We use the library directly, without its server or a hosted voice framework.

For synthesis, run `python3 -m engine.voice.tts_models`, then `python3 -m scripts.check_synthesis`. This exercises real audio generation, cancellation and another utterance without reloading the model. An optional output WAV path saves a sample. It does not use your microphone or call a paid API. Kokoro weights are Apache-2.0; the accompanying eSpeak NG data is GPL-licensed. The weight license remains beside the cached model. See [Kokoro voice mapping](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html) and [eSpeak NG licensing](https://github.com/espeak-ng/espeak-ng/blob/master/COPYING).

On the development Mac, the larger recognizer reduced first-clip word error from 16.7% to zero on the two public recordings; first partial text arrived around one second. These read-speech fixtures are regression checks, not evidence of accuracy on conversational speech in a room. Pi and mobile performance still need device testing.

### Background eligibility and usage

The scheduler owns reminder delivery times. Context review cannot turn a reminder
into an early alert, and facts extracted from an already-announced source cannot
independently announce that source again. Research preparation stays internal.
The model decides relevance and wording after these checks, using learned rules.

Context review checks revision markers before loading a prompt. It runs at most
once per 30 minutes, and only after a memory change, completed job, or local date
change. Mail triage receives standing rules and bounded matching facts. Memory
extraction receives candidate facts, registries, and a short conversation window,
with read tools for resolving missing context rather than the whole day snapshot.

Background usage is recorded in `assistant.source_items` under `runtime-usage`:
provider token/cache counters, elapsed time, and input size, without prompt text.
Memory extraction already records metrics in `memory.memory_jobs`. Provider cost
estimates are not subscription charges, and cached-token fields may overlap input
token totals. Missing metrics are unknown, not zero usage.
