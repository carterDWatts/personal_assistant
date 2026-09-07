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
