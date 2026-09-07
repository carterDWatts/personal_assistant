# Personal assistant

A personal assistant built around a shared knowledge map. The map is a Postgres schema on Supabase that every agent on every device reads and writes: facts as time-bounded assertions with full transition history, relationships between entities, an append-only log of everything that happened, and the plans, rules and questions that drive a short spoken check-in every morning.

## Layout

```
assistant.py           talk, morning, snapshot, status
engine/                the conversation engine: map access, tools, context, runtimes
prompts/               the persona and the morning instructions
supabase/migrations/   the schema, in SQL
supabase/tests/        behavioral checks for the schema
eval/                  knowledge-update and abstention cases
scripts/                test.sh runs the suite, testdb.sh keeps a local test map, push.sh pushes migrations
docs/knowledge-map.md  how the map works
docs/engine.md         how the engine works
docs/research/         the research the design rests on
docs/design-v0.1.md    the original design doc
```

## Running it

```bash
pip3 install -r requirements.txt
export ASSISTANT_DATABASE_URL='postgresql://...'   # the project's session pooler URI
python3 assistant.py talk
```

For anything exploratory, use the test map instead of the real one:

```bash
scripts/testdb.sh up                                # a local Postgres with the migrations applied
export ASSISTANT_TEST_DATABASE_URL="$(scripts/testdb.sh url)"
python3 assistant.py talk --test
```

`docs/engine.md` covers the rest.

## The map

`docs/knowledge-map.md` explains the schema. To prove a change before pushing it:

```bash
scripts/test.sh
```

To push migrations to the project:

```bash
supabase link --project-ref koauvyfxewczcajnlrfp
supabase db push
```

## The eval set

`eval/cases.json` holds knowledge-update and abstention cases: what was said or synced, the question, the answer the assistant must give, and what the current views must show. It is the regression check for extraction, retrieval and consolidation, written before any of that logic exists so the logic is held to it rather than the other way round.

## Mac app

```bash
scripts/build-mac.sh
open "build/Personal Assistant.app"
```

The build uses `python3`; set `PYTHON` if your dependencies are in a different interpreter. The app runs the engine from this checkout, so keep the folder in place. It reads literal `export ASSISTANT_DATABASE_URL=...` and `ASSISTANT_TEST_DATABASE_URL=...` lines from `~/.zshrc` when launched from Finder. It never executes that file. Test mode defaults to the local database created by `scripts/testdb.sh up` if no test URL is set.

The app connects automatically when opened and remembers your selected model and memory environment. Choosing Claude or ChatGPT, or switching test memory, reconnects automatically. Both models use the same shared transcript and knowledge map. Replies use the current conversation immediately; a smaller model saves structured memory in the background, with its progress shown separately. The microphone starts a voice conversation; Stop interrupts the reply. Allow Microphone and Speech Recognition when macOS asks. Speech is transcribed on-device when supported; otherwise macOS may use Apple's speech service. Playback uses installed macOS voices. This first version pauses the microphone during replies; it is not a full-duplex voice engine.

ChatGPT uses your Codex subscription login through the official app server. Sign in with `codex login` if needed. API-key accounts are rejected. `ASSISTANT_OPENAI_MODEL` optionally selects a model; otherwise Codex chooses its default. Claude uses the existing Claude login and rejects API billing environment variables. Reported SDK dollar estimates are not invoices or proof of subscription charges.

For terminal ChatGPT conversations:

```bash
ASSISTANT_RUNTIME=codex python3 assistant.py talk
```
