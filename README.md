# Morning agent

A personal assistant built around a shared knowledge map. The map is a Postgres schema on Supabase that every agent on every device reads and writes: facts as time-bounded assertions with full transition history, relationships between entities, an append-only log of everything that happened, and the plans, rules and questions that drive a short spoken check-in every morning.

## Layout

```
supabase/migrations/   the schema, in SQL
supabase/tests/        behavioral checks for the schema
scripts/               test_migration.sh runs the checks in a throwaway Postgres container
docs/knowledge-map.md  how the map works
docs/research/         the research the design rests on
docs/design-v0.1.md    the original design doc
```

## The map

`docs/knowledge-map.md` explains the schema. To prove a migration before pushing it:

```bash
scripts/test_migration.sh
```

To push it to the project:

```bash
supabase link --project-ref koauvyfxewczcajnlrfp
supabase db push
```

## The eval set

`eval/cases.json` holds knowledge-update and abstention cases: what was said or synced, the question, the answer the assistant must give, and what the current views must show. It is the regression check for extraction, retrieval and consolidation, written before any of that logic exists so the logic is held to it rather than the other way round.
