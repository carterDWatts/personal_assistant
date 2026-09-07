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
pip3 install claude-agent-sdk "psycopg[binary]"
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
