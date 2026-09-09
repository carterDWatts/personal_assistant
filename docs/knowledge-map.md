# The knowledge map

The knowledge map is the assistant's memory: a Postgres schema on Supabase named `memory`, built in SQL. Every agent on every device reads from it and writes to it, so the structure has to carry the guarantees the agents cannot be trusted to keep by themselves. The migration is `supabase/migrations/20260906000000_knowledge_map.sql`; the checks are `supabase/tests/knowledge_map_test.sql`.

## Facts are time-bounded assertions with two clocks

An assertion says that an entity had an attribute with a value over an interval. The interval, `valid`, is the world clock: true from this moment, until that moment, or still true when the upper bound is open. `recorded_at` and `superseded_at` are the system clock: when the map learned the fact and when it stopped treating it as current. The two diverge whenever a source arrives late. An email read tonight can establish that something has been true since last week, and the map records both dates.

A contradicted value is never edited or deleted. Its interval is closed and it points at the assertion that replaced it through `superseded_by`. The closed rows are the transition history, and the `transitions` view reads them as from-value, to-value, when.

Whether a new value replaces the old one depends on the attribute's cardinality, declared in the registry. Where the car is parked is single-valued, so a new location closes the previous one. Hobbies are multi-valued, so each value has its own interval and closes on its own.

"Currently true" and "trusted" are separate columns. `valid` decides what is current. `rank` marks a value as deprecated when it turns out to have been wrong rather than merely outdated. `confidence` grades how sure the map is. Relationships between entities follow the same shape as assertions, with a real foreign key to the object entity and a properties payload.

## Observations are the record

Dated activity and quantities live in `memory.records`: an event day, stable category and slot, actual/planned/retracted status, numeric values with units and evidence basis, details, an optional entity link, and the source message. These complement changing attributes such as an address. A meal is a dated event; a daily calorie total is a query over actual meals, not another mutable belief. Measurements and estimates remain distinguishable. Queries retain gaps and separate units instead of silently assuming zero or converting them.

Corrections require the record ID and expected version. The database retains immutable revisions, and an older source cannot replace a newer correction. Replayed extraction cannot duplicate the same entry. The conversational agent can save these entries immediately; the independent memory worker remains a second write path and keeps a receipt of its operations and validation failures. A new chat turn no longer cancels extraction.

Morning sessions store their chosen agenda and progress in `memory.routine_progress`. The agenda comes from saved preferences, not hard-coded topics. Completed sections survive model restarts and are not reopened by a repeated completion call.

`observations` is an append-only log of everything that happened: a sentence in a conversation, an email, a calendar change, a sync run, an inference. Assertions point at the observation they came from, and `assertion_sources` lists every observation that ever supported one, including re-confirmations. Conversations and messages are stored in full for every agent, and an observation can cite the message it came from, so any fact can be traced to the words that produced it.

The base tables cannot be updated or deleted by anyone. Triggers refuse it. The assertion tables allow updates only to metadata and to the closing bound of the interval. The fact's identity, its entity, attribute, value and start, is immutable.

## Writes go through functions

`assert_fact` and `assert_relationship` are the only way values enter the map. Each takes an advisory lock on the entity and attribute, locks the currently open row, and then does one of three things. The same value again re-confirms the open row, reinforces its salience and adds the observation as a source. Otherwise the new value becomes current, whatever its start. Every value it overlaps ends where it begins if it started earlier, or is deprecated if it started later, since a value that began after the new one was wrong for its whole life. That is how "I've actually been at Globex since August" corrects "I work at Acme" without anyone deciding which is newer: the latest assertion is current, and the interval arithmetic does the rest. Narrating the past is explicit: pass an end as well as a start, and the value is inserted closed, into a gap. History that would overlap a known value is refused, because that is a correction to be made deliberately by retracting or deprecating the conflicting row first.

`retract_fact` closes a value that stopped being true with nothing replacing it. `deprecate_fact` marks a value as wrong. `confirm_fact` records a re-verification. Behind the functions, two exclusion constraints on the validity range guarantee that a single-valued attribute never has two live values and a multi-valued one never has the same value live twice, so a concurrent write from another device fails loudly instead of corrupting the current state.

## Entities resolve in layers

An entity has a type, a canonical name, a description and any number of aliases. `find_entity` matches an alias exactly first, then falls back to trigram similarity on the name. `upsert_entity` creates an entity only when neither matches. Every confirmed surface form is written back as an alias so resolution compounds. Embeddings live in their own table keyed by model name, and an index is created per model, so changing the embedding model never rewrites the entity table.

`merge_entities` folds one entity into another: assertions, relationships, plans, rules and connectors move to the survivor, aliases are copied, and the merged row stays behind pointing at the survivor. It refuses when both entities hold a live value for the same single-valued attribute, which is a conflict to resolve before merging, not during it.

## Views are the only read surface

`current_assertions` and `current_relationships` return open, non-deprecated intervals for live entities, joined with entity names and the registry, and flag rows that are past their attribute's stale window. `assertion_history` returns every value with both clocks. `transitions` returns each change of a single-valued attribute. Agents read these and never the base tables.

## The operational tables reference the map

Plans hold planned versus actual per day. A plan the agent derived from the map itself, rather than from you or a source, is inserted with status `proposed`, origin `map` and a rationale, and becomes `planned` when you accept it. Things that happened without a plan are recorded with origin `unplanned`. Rules hold mandates, preferences and tuning parameters, with one active row per tuning key. Questions are the persistent candidate queue for the morning session, including uncertain entity merges and the agent's own proposals. Connectors record which sources exist, what each needs from you to enable it, and its sync cursor. Secrets never live in the map.

## Access

The knowledge tables have row-level security enabled and privileged access is kept on the engine host. The iPhone authenticates through Supabase Auth and sends validated commands through the gateway; it never receives database or service-role credentials. The current deployment allows one owner. Both model adapters use the engine's memory tools.

## Applying it

Migrations live in `supabase/migrations` and are pushed with the Supabase CLI. `scripts/test.sh` applies every migration to a throwaway Postgres 17 container with pgvector and runs the behavioral checks, so the SQL is proven before it touches the project. After the first push, expose the `memory` schema in the project's API settings so PostgREST can serve it.
