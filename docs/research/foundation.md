# Knowledge map foundation

What the research supports for the memory store, distilled from three passes: production agent memory systems, temporal data modeling and Postgres mechanics on Supabase, and the 2024 to 2026 literature on agent memory, consolidation and forecasting. Sources are at the end.

## What the field agrees on

**1. Every fact is a time-bounded assertion with two clocks.** Valid time says when the fact was true in the world. Transaction time says when the system learned it and when it stopped believing it. The systems that get knowledge updates right (Zep/Graphiti, Engram, XTDB, the AGM belief-revision work) all carry both. The second clock matters for us specifically because sources arrive late and out of order: an email read tonight can establish something that became true last week, and the map must record both the world date and the learning date. Transaction time is nearly free to capture and impossible to backfill.

**2. Invalidate, never delete.** A contradicted value gets its interval closed and a pointer to the row that replaced it. Every system that overwrites or hard-deletes has a documented stale-fact failure: Mem0 in both its modes, LangMem in its own tutorial, Honcho's five-minute purge, OpenAI's rewrite-in-place. Transition history is what remains after closing intervals, and it is exactly what prediction needs.

**3. "Currently true" and "trusted" are separate axes.** Wikidata's own documented rule: the end-time marks what is current, rank marks which of several simultaneous values to believe. Conflating them is the most common modeling mistake found.

**4. Observations are the system of record. Assertions are a derived projection.** An append-only log of everything that happened (a message, an email, a calendar change, a sync result) takes zero coordination between concurrent writers. All the delicate logic lives in the projection step, and the projection can be rebuilt from the log after a bug.

**5. Deciding what is current is SQL, not a model.** A 2026 result shows LLM-as-judge freshness tracking falls from 75% to 61% as context grows, while a deterministic newest-open-interval rule stays at 82 to 93%. The model's job is semantic: is this new statement about the same thing, and does it actually conflict. Ordering by time is the database's job.

**6. Provenance lives on the row.** Each assertion points at the observation it came from, who asserted it (user-stated outranks agent-inferred), and a confidence. Systems that keep provenance in a side audit log drift out of sync and cannot answer "why do we believe this."

**7. Single-valued versus multi-valued attributes must be declared.** Cognee's lesson: automatic supersession is only correct for attributes that have one value at a time (where the car is parked). Multi-valued ones (hobbies, friends) accumulate and close individually. This is a flag on the attribute, not a judgment call at write time.

**8. Entity resolution is layered.** Exact alias match first, then trigram similarity, then embeddings, fused by reciprocal rank. Auto-merge only above a high bar. Below it, queue the merge as a question rather than guessing, since a wrong merge is far harder to undo than a delayed one. Every confirmed match is written back as an alias so coverage compounds.

**9. Consolidation is a separate pass, dedup-heavy and summarize-conservative.** Every mature system runs a fast synchronous write path plus a slower background reconciliation. The strongest 2026 result on this shows aggressive summarization collapses recall (78% to 48%) while deduplication alone stays at baseline. Structure the nightly pass in three widening scopes: within one entity's history, across duplicate entities, across the whole map. Gate promotion from a probationary buffer into durable memory on a quality check.

**10. Salience is not truth.** A decay score with reinforcement on access (Ebbinghaus-style, `strength` plus `last_accessed_at`) ranks what to surface and what to archive. It never decides what is true. Keep it as its own column, beside the validity interval, not instead of it.

**11. Prediction from transitions needs no trained model.** The best-evidenced portable approach: mine confidence-ranked rules over a recent window of closed intervals with SQL self-joins, then hand the small, strictly time-ordered slice to the model to forecast. Ascending time order measurably matters.

**12. Plain Postgres is enough.** Letta runs on Aurora at scale, Honcho and MIRIX are Postgres-native, the graph-database systems treat their own Postgres options as second class. Recursive CTEs cover the shallow traversals this workload has.

## What to avoid

- Overwriting or deleting facts, in any code path.
- A materialized view for current state. It reintroduces staleness. Use a plain view over a partial index on open intervals.
- A naive trigger as the only guard for closing the previous interval. Two concurrent writers can both close the same row and both open a new one. The exclusion constraint on the validity range is the non-negotiable backstop.
- One JSONB blob of attributes per entity. One row per assertion, single value in the payload.
- Auto-merging entities on one similarity signal.
- Trusting vendor leaderboards. LoCoMo has 6.4% corrupted ground truth and a judge that accepts most wrong answers. Build a private eval around knowledge-update and abstention questions instead.
- Instruction-based freshness. No system surveyed made "check for updates" reliable by prompting.

## Supabase facts that shape the schema

- The project runs Postgres 17, so the native `WITHOUT OVERLAPS` key from Postgres 18 is not available. Use `tstzrange` plus `btree_gist` and an `EXCLUDE` constraint, which is the identical mechanism and works on every version.
- Available and useful: pgvector (HNSW), pg_trgm, btree_gist, pg_cron (the nightly pass), pgmq (async jobs like embedding and entity resolution), pg_net, pg_jsonschema (validate assertion payloads per attribute), ltree.
- Not available: Apache AGE. Graph traversal is recursive CTEs over the relationship table.
- Realtime `postgres_changes` gives every device a live feed of writes for free.
- Exclusion constraints cannot be `ON CONFLICT DO UPDATE` arbiters. The write path is a SQL function that takes an advisory lock on (entity, attribute), locks the open row, closes it, inserts the new one, and lets the constraint raise `23P01` if anything slipped through.

## Proposed shape for module one

**Core map.** `observations` (append-only record: source, message reference, raw payload, occurred and recorded times). `entities` (type, canonical name, description, merged-into pointer). `entity_aliases`. `attributes` (registry: name, value type, single or multi valued, default stale window). `assertions` (entity, attribute, JSONB value, validity range, rank, confidence, level stated or inferred, recorded and superseded times, superseded-by pointer, source observation, asserted by). `relationship_assertions` (same shape with a real foreign-key target entity). `entity_embeddings` keyed by model name, so swapping the embedding model never rewrites the entity table.

**Views.** `current_assertions` and `current_relationships` expose only open, non-deprecated intervals. History is a separate view. Nothing reads the base tables directly.

**Write path.** `assert_fact()` and `assert_relationship()` as SQL functions called over RPC from any device. `record_observation()` for the log. Everything else is derived.

**Operational tables that reference the map.** Plans and outcomes, rules and tuning, the question queue, conversations and messages of every agent, connectors and sync cursors. Whether these stay dedicated tables or become entity types inside the generic map is the first design decision to make together.

**Nightly pass.** A pg_cron job plus the consolidation agent: dedupe within entities, merge duplicate entities above the bar and queue the rest as questions, reconcile across entities, recompute salience, expire dead questions, and report.

## Open decisions before writing the schema

1. Generic map versus dedicated tables for plans, outcomes, rules, questions. Recommendation: dedicated tables that reference entities, because the daily loops query them in fixed shapes.
2. How strict the attribute registry is. Recommendation: every attribute must exist in the registry with a declared cardinality and value type, and the model can create new ones through a tool that inserts a registry row first.
3. Whether relationships need their own attribute payload from day one. Recommendation: a JSONB properties column, empty until needed.
4. The first private eval set: twenty knowledge-update and abstention questions written against the schema before any consolidation logic exists.

## Sources

Memory systems and papers:

- Zep, a temporal knowledge graph for agent memory: https://arxiv.org/abs/2501.13956
- Mem0: https://arxiv.org/abs/2504.19413, and its open stale-fact issue: https://github.com/mem0ai/mem0/issues/4956
- Honcho: https://github.com/plastic-labs/honcho
- Letta on Aurora Postgres: https://aws.amazon.com/blogs/database/how-letta-builds-production-ready-ai-agents-with-amazon-aurora-postgresql
- Engram, bi-temporal facts with supersession: https://arxiv.org/abs/2606.09900
- Memory for autonomous LLM agents, 2026 survey: https://arxiv.org/abs/2603.07670
- Belief revision semantics for versioned memory: https://arxiv.org/abs/2603.17244
- Deterministic freshness resolution versus an LLM judge: https://arxiv.org/abs/2606.01435
- Complementary learning systems consolidation, with the over-summarization result: https://arxiv.org/abs/2605.08538
- Generative Agents, retrieval scoring and the reflection trigger: https://arxiv.org/abs/2304.03442
- TLogic, temporal rule mining: https://arxiv.org/abs/2112.08025, and GenTKG: https://arxiv.org/abs/2310.07793
- LongMemEval: https://arxiv.org/abs/2410.10813, and the LoCoMo audit: https://penfieldlabs.substack.com/p/we-audited-locomo-64-of-the-answer

Data modeling:

- Wikidata ranking and time qualifiers: https://www.wikidata.org/wiki/Help:Ranking
- XTDB on bitemporality: https://docs.xtdb.com/about/time-in-xtdb.html
- Fowler, bitemporal history: https://martinfowler.com/articles/bitemporal-history.html
- pg_bitemporal: https://github.com/scalegenius/pg_bitemporal
- A community Postgres port of Graphiti: https://github.com/uahic/graphiti-postgres

Postgres and Supabase:

- Range types and exclusion constraints: https://www.postgresql.org/docs/current/rangetypes.html
- btree_gist: https://www.postgresql.org/docs/current/btree-gist.html
- Supabase on range columns: https://supabase.com/blog/range-columns
- Supabase extensions: https://supabase.com/docs/guides/database/extensions
- Apache AGE on Supabase, not available: https://github.com/orgs/supabase/discussions/13263
- Supabase hybrid search with reciprocal rank fusion: https://supabase.com/docs/guides/ai/hybrid-search
