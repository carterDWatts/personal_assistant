-- Knowledge map: the assistant's memory.
--
-- Every fact is a time-bounded assertion with two clocks (when it was true,
-- when we learned it). Contradicted values are closed and pointed at their
-- replacement, never deleted. Observations are the append-only record that
-- every assertion points back to. Writes to assertions go through the
-- functions at the bottom of this file, which hold a lock per (entity,
-- attribute) and let the exclusion constraints catch anything that slips.

create schema if not exists memory;

create extension if not exists btree_gist with schema extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists vector with schema extensions;

-- ---------------------------------------------------------------------------
-- Conversations and messages: the full transcript of every agent, on any device.
-- ---------------------------------------------------------------------------

create table memory.conversations (
  id                 uuid primary key default gen_random_uuid(),
  agent              text not null,                       -- morning | chat | night | claude_app | ...
  day                date not null default current_date,
  device             text,
  runtime            text,                                -- which runtime module ran it (claude-agent-sdk, ...)
  runtime_session_id text,                                -- the runtime's own id, for resume
  started_at         timestamptz not null default now(),
  ended_at           timestamptz,
  ended_by           text check (ended_by in ('user', 'agent', 'silence', 'error')),
  summary            text,
  metrics            jsonb not null default '{}'::jsonb   -- turns, questions asked/answered, first_word_ms, ...
);
comment on table memory.conversations is 'One row per conversation with any agent on any device. Metrics feed the question budget.';

create table memory.messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid not null references memory.conversations(id) on delete cascade,
  seq             integer not null,
  role            text not null check (role in ('user', 'assistant', 'system', 'tool')),
  content         text,
  payload         jsonb,                                  -- tool calls, raw blocks, anything the runtime emitted
  created_at      timestamptz not null default now(),
  unique (conversation_id, seq)
);
comment on table memory.messages is 'Append-only transcript. Assertions cite messages through observations.';

-- ---------------------------------------------------------------------------
-- Observations: the append-only system of record. Assertions are derived from these.
-- ---------------------------------------------------------------------------

create table memory.observations (
  id          bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),         -- when it happened in the world
  recorded_at timestamptz not null default now(),         -- when the system learned of it
  source      text not null,                              -- conversation | gmail | google_calendar | cli | consolidation | ...
  source_ref  text,                                       -- the source's own id (email id, event id, ...)
  agent       text,                                       -- which agent or device recorded it
  kind        text not null,                              -- statement | email | calendar_event | sync | inference | merge | ...
  content     text,                                       -- the observation in words
  payload     jsonb,                                      -- the raw structured form, if any
  message_id  bigint references memory.messages(id)       -- the transcript message it came from, if any
);
create index observations_occurred_idx on memory.observations (occurred_at desc);
create index observations_source_idx on memory.observations (source, source_ref);
comment on table memory.observations is 'Everything that happened, append-only. Every assertion points at the observation it came from.';

-- ---------------------------------------------------------------------------
-- Entities, aliases, embeddings.
-- ---------------------------------------------------------------------------

create table memory.entities (
  id                    uuid primary key default gen_random_uuid(),
  type                  text not null,                    -- person | place | project | vehicle | organization | commitment | topic | ...
  name                  text not null,                    -- canonical name
  description           text,
  created_at            timestamptz not null default now(),
  created_by            text not null,
  source_observation_id bigint references memory.observations(id),
  merged_into           uuid references memory.entities(id),
  retired_at            timestamptz
);
create unique index entities_live_name_idx on memory.entities (type, lower(name)) where merged_into is null;
create index entities_name_trgm_idx on memory.entities using gist (name extensions.gist_trgm_ops) where merged_into is null;
comment on table memory.entities is 'The things the assistant knows about. A merged entity keeps its row and points at the survivor.';

create table memory.entity_aliases (
  id         bigint generated always as identity primary key,
  entity_id  uuid not null references memory.entities(id) on delete cascade,
  alias      text not null,
  alias_norm text generated always as (lower(btrim(alias))) stored,
  source     text,
  confidence real not null default 1.0 check (confidence between 0 and 1),
  created_at timestamptz not null default now(),
  unique (entity_id, alias_norm)
);
create index entity_aliases_norm_idx on memory.entity_aliases (alias_norm);
comment on table memory.entity_aliases is 'Surface forms that resolve to an entity. Every confirmed match is written back here.';

create table memory.entity_embeddings (
  entity_id  uuid not null references memory.entities(id) on delete cascade,
  model      text not null,                               -- embedding model name; an index is created per model
  embedding  extensions.vector not null,
  updated_at timestamptz not null default now(),
  primary key (entity_id, model)
);
comment on table memory.entity_embeddings is 'Name and description embeddings keyed by model, so the model can change without touching entities.';

-- ---------------------------------------------------------------------------
-- Registries: what attributes and relations exist, and how they behave.
-- ---------------------------------------------------------------------------

create table memory.attributes (
  name        text primary key,                           -- parked_at | schedule | employer | ...
  description text,
  value_type  text not null check (value_type in ('text', 'number', 'boolean', 'date', 'timestamp', 'json')),
  cardinality text not null check (cardinality in ('single', 'multi')),   -- single: a new value supersedes the old one
  stale_after interval,                                   -- re-verify after this long; null means never
  importance  smallint not null default 2 check (importance between 1 and 3),
  created_at  timestamptz not null default now(),
  created_by  text not null
);
comment on table memory.attributes is 'Every attribute must be registered before it can be asserted. Cardinality decides whether a new value replaces or joins the old.';

create table memory.relations (
  name        text primary key,                           -- lives_at | employed_by | owns | member_of | ...
  description text,
  cardinality text not null check (cardinality in ('single', 'multi')),   -- single: one object per subject at a time
  inverse     text,                                       -- name of the relation read from the object's side
  created_at  timestamptz not null default now(),
  created_by  text not null
);
comment on table memory.relations is 'Every relation must be registered before it can be asserted.';

-- ---------------------------------------------------------------------------
-- Assertions: scalar attributes of an entity, time-bounded.
-- ---------------------------------------------------------------------------

create table memory.assertions (
  id                    uuid primary key default gen_random_uuid(),
  entity_id             uuid not null references memory.entities(id),
  attribute             text not null references memory.attributes(name),
  value                 jsonb not null,
  value_hash            text generated always as (md5(value::text)) stored,
  cardinality           text not null check (cardinality in ('single', 'multi')),   -- copied from the registry on insert
  valid                 tstzrange not null,               -- [true from, true until); unbounded upper means still true
  rank                  text not null default 'normal' check (rank in ('preferred', 'normal', 'deprecated')),
  confidence            real not null default 1.0 check (confidence between 0 and 1),
  level                 text not null default 'stated' check (level in ('stated', 'inferred', 'synced')),
  asserted_by           text not null,
  source_observation_id bigint references memory.observations(id),
  recorded_at           timestamptz not null default now(),
  superseded_at         timestamptz,
  superseded_by         uuid references memory.assertions(id),
  last_confirmed_at     timestamptz not null default now(),
  strength              integer not null default 1,      -- salience: reinforced on access, decays in ranking, never decides truth
  last_accessed_at      timestamptz,
  constraint assertions_valid_nonempty check (not isempty(valid)),
  -- one live value at a time for single-valued attributes
  constraint assertions_single_no_overlap exclude using gist (entity_id with =, attribute with =, valid with &&)
    where (cardinality = 'single' and rank <> 'deprecated'),
  -- the same value cannot be live twice for multi-valued attributes
  constraint assertions_multi_no_overlap exclude using gist (entity_id with =, attribute with =, value_hash with =, valid with &&)
    where (cardinality = 'multi' and rank <> 'deprecated')
);
create index assertions_current_idx on memory.assertions (entity_id, attribute) where upper_inf(valid) and rank <> 'deprecated';
create index assertions_recorded_idx on memory.assertions (recorded_at desc);
comment on table memory.assertions is 'Time-bounded attribute values. Written only through memory.assert_fact and memory.retract_fact.';

create table memory.assertion_sources (
  assertion_id   uuid not null references memory.assertions(id) on delete cascade,
  observation_id bigint not null references memory.observations(id),
  added_at       timestamptz not null default now(),
  primary key (assertion_id, observation_id)
);
comment on table memory.assertion_sources is 'Every observation that supported an assertion, including re-confirmations.';

-- ---------------------------------------------------------------------------
-- Relationships: entity to entity, time-bounded, with their own properties.
-- ---------------------------------------------------------------------------

create table memory.relationships (
  id                    uuid primary key default gen_random_uuid(),
  subject_id            uuid not null references memory.entities(id),
  relation              text not null references memory.relations(name),
  object_id             uuid not null references memory.entities(id),
  properties            jsonb not null default '{}'::jsonb,
  cardinality           text not null check (cardinality in ('single', 'multi')),
  valid                 tstzrange not null,
  rank                  text not null default 'normal' check (rank in ('preferred', 'normal', 'deprecated')),
  confidence            real not null default 1.0 check (confidence between 0 and 1),
  level                 text not null default 'stated' check (level in ('stated', 'inferred', 'synced')),
  asserted_by           text not null,
  source_observation_id bigint references memory.observations(id),
  recorded_at           timestamptz not null default now(),
  superseded_at         timestamptz,
  superseded_by         uuid references memory.relationships(id),
  last_confirmed_at     timestamptz not null default now(),
  constraint relationships_valid_nonempty check (not isempty(valid)),
  constraint relationships_single_no_overlap exclude using gist (subject_id with =, relation with =, valid with &&)
    where (cardinality = 'single' and rank <> 'deprecated'),
  constraint relationships_multi_no_overlap exclude using gist (subject_id with =, relation with =, object_id with =, valid with &&)
    where (cardinality = 'multi' and rank <> 'deprecated')
);
create index relationships_current_idx on memory.relationships (subject_id, relation) where upper_inf(valid) and rank <> 'deprecated';
create index relationships_object_idx on memory.relationships (object_id, relation) where upper_inf(valid) and rank <> 'deprecated';
comment on table memory.relationships is 'Time-bounded links between entities. Written only through memory.assert_relationship and memory.retract_relationship.';

-- ---------------------------------------------------------------------------
-- Operational tables. They reference the map and drive the daily loops.
-- ---------------------------------------------------------------------------

create table memory.plans (
  id                    bigint generated always as identity primary key,
  day                   date not null,
  item                  text not null,
  category              text,                             -- gym | study | work | errand | social | ...
  entity_id             uuid references memory.entities(id),
  status                text not null default 'planned'
                        check (status in ('proposed', 'planned', 'done', 'partial', 'skipped', 'dropped')),
  origin                text not null check (origin in ('user', 'agent', 'map', 'calendar', 'unplanned')),
                                                          -- map: proposed by the agent from the knowledge map itself
  rationale             text,                             -- why the agent proposed it
  outcome_note          text,
  source_observation_id bigint references memory.observations(id),
  created_by            text not null,
  created_at            timestamptz not null default now(),
  resolved_at           timestamptz
);
create index plans_day_idx on memory.plans (day, status);
comment on table memory.plans is 'Planned versus actual, per day. Proposed rows are the agent''s own suggestions; unplanned rows are things that happened without a plan.';

create table memory.rules (
  id                    bigint generated always as identity primary key,
  kind                  text not null check (kind in ('mandate', 'preference', 'tuning')),
  key                   text,                             -- tuning parameters are keyed; one active row per key
  text                  text not null,
  value                 jsonb,
  status                text not null default 'active' check (status in ('proposed', 'active', 'retired')),
  entity_id             uuid references memory.entities(id),   -- scope, when the rule is about one thing
  source_observation_id bigint references memory.observations(id),
  created_by            text not null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  retired_at            timestamptz
);
create unique index rules_active_tuning_idx on memory.rules (key) where kind = 'tuning' and status = 'active';
comment on table memory.rules is 'Standing mandates, preferences and tuning parameters, learned in-band. Every agent reads these.';

create table memory.questions (
  id            bigint generated always as identity primary key,
  kind          text not null check (kind in ('stale', 'gap', 'policy', 'merge', 'proposal', 'open')),
  text          text not null,
  ref_table     text,                                     -- what it is about: assertions | plans | rules | entities
  ref_id        text,
  score         real not null default 2.0,                -- expected value of the answer
  times_asked   integer not null default 0,
  created_by    text not null,
  created_at    timestamptz not null default now(),
  asked_at      timestamptz,
  asked_in      uuid references memory.conversations(id),
  deferred_until date,
  closed_at     timestamptz,
  closed_reason text,
  answer        text
);
create index questions_open_idx on memory.questions (score desc) where closed_at is null;
comment on table memory.questions is 'The persistent candidate queue for the morning session: stale facts, gaps, policy confirmations, uncertain merges, proposals, and anything worth asking.';

create table memory.connectors (
  name         text primary key,                          -- google_calendar | gmail | github | ...
  status       text not null default 'available' check (status in ('available', 'needs_setup', 'enabled', 'disabled', 'error')),
  entity_id    uuid references memory.entities(id),       -- what it tracks, when it is about one thing
  config       jsonb not null default '{}'::jsonb,        -- non-secret configuration
  needs        text,                                      -- what the user must provide to enable it
  cursor       jsonb,                                     -- sync state
  last_sync_at timestamptz,
  last_error   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table memory.connectors is 'Sources the assistant can sync, discovered conversationally. Secrets never live here.';

-- ---------------------------------------------------------------------------
-- Structural guards.
-- ---------------------------------------------------------------------------

create or replace function memory.forbid_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name;
end $$;

create trigger observations_append_only before update or delete on memory.observations
  for each row execute function memory.forbid_change();
create trigger messages_append_only before update or delete on memory.messages
  for each row execute function memory.forbid_change();

-- A fact's identity never changes; only its metadata and its closing bound may.
create or replace function memory.protect_assertion() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'assertions are never deleted; retract or deprecate instead';
  end if;
  if new.attribute <> old.attribute or new.value <> old.value or lower(new.valid) <> lower(old.valid)
     or (new.entity_id <> old.entity_id and coalesce(current_setting('memory.merging', true), '') <> 'on') then
    raise exception 'an assertion''s entity, attribute, value and start are immutable; assert a new one';
  end if;
  return new;
end $$;
create trigger assertions_protect before update or delete on memory.assertions
  for each row execute function memory.protect_assertion();

create or replace function memory.protect_relationship() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'relationships are never deleted; retract or deprecate instead';
  end if;
  if new.relation <> old.relation or lower(new.valid) <> lower(old.valid)
     or ((new.subject_id <> old.subject_id or new.object_id <> old.object_id)
         and coalesce(current_setting('memory.merging', true), '') <> 'on') then
    raise exception 'a relationship''s subject, relation, object and start are immutable; assert a new one';
  end if;
  return new;
end $$;
create trigger relationships_protect before update or delete on memory.relationships
  for each row execute function memory.protect_relationship();

-- Values must match the registered type; cardinality is copied from the registry.
create or replace function memory.validate_value(p_type text, p_value jsonb) returns void language plpgsql immutable as $$
declare
  t text := jsonb_typeof(p_value);
begin
  if p_type = 'text' and t <> 'string' then
    raise exception 'value must be a JSON string for a text attribute';
  elsif p_type = 'number' and t <> 'number' then
    raise exception 'value must be a JSON number for a number attribute';
  elsif p_type = 'boolean' and t <> 'boolean' then
    raise exception 'value must be a JSON boolean for a boolean attribute';
  elsif p_type = 'date' then
    if t <> 'string' then raise exception 'value must be an ISO date string'; end if;
    perform (p_value #>> '{}')::date;
  elsif p_type = 'timestamp' then
    if t <> 'string' then raise exception 'value must be an ISO timestamp string'; end if;
    perform (p_value #>> '{}')::timestamptz;
  end if;
end $$;

create or replace function memory.prepare_assertion() returns trigger language plpgsql as $$
declare
  a memory.attributes;
begin
  select * into a from memory.attributes where name = new.attribute;
  if not found then
    raise exception 'attribute % is not registered; register it first', new.attribute;
  end if;
  perform memory.validate_value(a.value_type, new.value);
  new.cardinality := a.cardinality;
  return new;
end $$;
create trigger assertions_prepare before insert on memory.assertions
  for each row execute function memory.prepare_assertion();

create or replace function memory.prepare_relationship() returns trigger language plpgsql as $$
declare
  r memory.relations;
begin
  select * into r from memory.relations where name = new.relation;
  if not found then
    raise exception 'relation % is not registered; register it first', new.relation;
  end if;
  if new.subject_id = new.object_id then
    raise exception 'an entity cannot relate to itself';
  end if;
  new.cardinality := r.cardinality;
  return new;
end $$;
create trigger relationships_prepare before insert on memory.relationships
  for each row execute function memory.prepare_relationship();

-- ---------------------------------------------------------------------------
-- Views. Agents read these, never the base tables.
-- ---------------------------------------------------------------------------

create view memory.current_assertions as
select a.id, a.entity_id, e.type as entity_type, e.name as entity_name,
       a.attribute, a.value, lower(a.valid) as valid_from,
       a.confidence, a.level, a.asserted_by, a.recorded_at, a.last_confirmed_at, a.strength,
       t.importance, t.stale_after,
       (t.stale_after is not null and a.last_confirmed_at + t.stale_after < now()) as stale
from memory.assertions a
join memory.entities e on e.id = a.entity_id
join memory.attributes t on t.name = a.attribute
where upper_inf(a.valid) and a.rank <> 'deprecated' and e.merged_into is null;
comment on view memory.current_assertions is 'What is true now. Stale rows are due for re-verification.';

create view memory.current_relationships as
select r.id, r.subject_id, s.type as subject_type, s.name as subject_name,
       r.relation, r.object_id, o.type as object_type, o.name as object_name,
       r.properties, lower(r.valid) as valid_from,
       r.confidence, r.level, r.asserted_by, r.recorded_at, r.last_confirmed_at
from memory.relationships r
join memory.entities s on s.id = r.subject_id
join memory.entities o on o.id = r.object_id
where upper_inf(r.valid) and r.rank <> 'deprecated' and s.merged_into is null and o.merged_into is null;
comment on view memory.current_relationships is 'Which entities are linked right now.';

create view memory.assertion_history as
select a.id, a.entity_id, e.name as entity_name, a.attribute, a.value,
       lower(a.valid) as valid_from, upper(a.valid) as valid_to,
       a.rank, a.confidence, a.level, a.asserted_by, a.recorded_at, a.superseded_at, a.superseded_by
from memory.assertions a
join memory.entities e on e.id = a.entity_id;
comment on view memory.assertion_history is 'Every value an attribute ever had, with both clocks.';

create view memory.transitions as
select o.entity_id, e.name as entity_name, o.attribute,
       o.value as from_value, n.value as to_value,
       lower(o.valid) as from_since, upper(o.valid) as changed_at,
       o.id as from_assertion_id, n.id as to_assertion_id
from memory.assertions o
join memory.assertions n on n.id = o.superseded_by
join memory.entities e on e.id = o.entity_id
where o.rank <> 'deprecated';
comment on view memory.transitions is 'Each change of a single-valued attribute: from what, to what, when. The raw material for prediction.';

-- ---------------------------------------------------------------------------
-- Write path. Every device calls these; nothing writes assertions directly.
-- ---------------------------------------------------------------------------

create or replace function memory.record_observation(
  p_source text, p_kind text, p_content text,
  p_payload jsonb default null, p_source_ref text default null, p_agent text default null,
  p_occurred_at timestamptz default now(), p_message_id bigint default null
) returns bigint language sql as $$
  insert into memory.observations (source, kind, content, payload, source_ref, agent, occurred_at, message_id)
  values (p_source, p_kind, p_content, p_payload, p_source_ref, p_agent, p_occurred_at, p_message_id)
  returning id
$$;

-- Assert a value. Single-valued: the same value re-confirms, a new value supersedes the open one.
-- A start earlier than the open value's start is recorded as history, ending where the open value began.
create or replace function memory.assert_fact(
  p_entity_id uuid, p_attribute text, p_value jsonb, p_asserted_by text,
  p_valid_from timestamptz default now(), p_confidence real default 1.0,
  p_level text default 'stated', p_observation_id bigint default null
) returns memory.assertions language plpgsql as $$
declare
  v_attr memory.attributes;
  v_open memory.assertions;
  v_new  memory.assertions;
  v_next timestamptz;
begin
  select * into v_attr from memory.attributes where name = p_attribute;
  if not found then
    raise exception 'attribute % is not registered; register it first', p_attribute;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_entity_id::text || '|' || p_attribute, 0));

  if v_attr.cardinality = 'single' then
    select * into v_open from memory.assertions
     where entity_id = p_entity_id and attribute = p_attribute and upper_inf(valid) and rank <> 'deprecated'
     for update;
  else
    select * into v_open from memory.assertions
     where entity_id = p_entity_id and attribute = p_attribute and upper_inf(valid) and rank <> 'deprecated'
       and value_hash = md5(p_value::text)
     for update;
  end if;

  if found and v_open.value = p_value then
    update memory.assertions
       set last_confirmed_at = now(), confidence = greatest(confidence, p_confidence), strength = strength + 1
     where id = v_open.id returning * into v_new;
    if p_observation_id is not null then
      insert into memory.assertion_sources (assertion_id, observation_id) values (v_new.id, p_observation_id)
      on conflict do nothing;
    end if;
    return v_new;
  end if;

  if found and p_valid_from >= lower(v_open.valid) then
    -- supersede: the open value ends where the new one begins
    update memory.assertions
       set valid = tstzrange(lower(valid), greatest(p_valid_from, lower(valid) + interval '1 microsecond'), '[)'),
           superseded_at = now()
     where id = v_open.id;
    insert into memory.assertions (entity_id, attribute, value, valid, confidence, level, asserted_by, source_observation_id)
    values (p_entity_id, p_attribute, p_value, tstzrange(p_valid_from, null, '[)'),
            p_confidence, p_level, p_asserted_by, p_observation_id)
    returning * into v_new;
    update memory.assertions set superseded_by = v_new.id where id = v_open.id;
  else
    -- history, or a fresh value: it must start in a gap and ends where the next known value begins
    if v_attr.cardinality = 'single' then
      if exists (select 1 from memory.assertions
                  where entity_id = p_entity_id and attribute = p_attribute and rank <> 'deprecated'
                    and valid @> p_valid_from) then
        raise exception 'a value of % already covers %; retract or deprecate it before recording history',
          p_attribute, p_valid_from;
      end if;
      select min(lower(valid)) into v_next from memory.assertions
       where entity_id = p_entity_id and attribute = p_attribute and rank <> 'deprecated'
         and lower(valid) > p_valid_from;
    else
      if exists (select 1 from memory.assertions
                  where entity_id = p_entity_id and attribute = p_attribute and rank <> 'deprecated'
                    and value_hash = md5(p_value::text) and valid @> p_valid_from) then
        raise exception 'that value of % already covers %; retract or deprecate it before recording history',
          p_attribute, p_valid_from;
      end if;
      select min(lower(valid)) into v_next from memory.assertions
       where entity_id = p_entity_id and attribute = p_attribute and rank <> 'deprecated'
         and value_hash = md5(p_value::text) and lower(valid) > p_valid_from;
    end if;
    insert into memory.assertions (entity_id, attribute, value, valid, confidence, level, asserted_by, source_observation_id)
    values (p_entity_id, p_attribute, p_value, tstzrange(p_valid_from, v_next, '[)'),
            p_confidence, p_level, p_asserted_by, p_observation_id)
    returning * into v_new;
  end if;

  if p_observation_id is not null then
    insert into memory.assertion_sources (assertion_id, observation_id) values (v_new.id, p_observation_id)
    on conflict do nothing;
  end if;
  return v_new;
end $$;

-- Close a value without replacing it: it stopped being true and nothing took its place.
create or replace function memory.retract_fact(
  p_assertion_id uuid, p_asserted_by text, p_valid_to timestamptz default now(), p_observation_id bigint default null
) returns memory.assertions language plpgsql as $$
declare
  v memory.assertions;
begin
  select * into v from memory.assertions where id = p_assertion_id for update;
  if not found or not upper_inf(v.valid) then
    raise exception 'assertion % is not open', p_assertion_id;
  end if;
  update memory.assertions
     set valid = tstzrange(lower(valid), greatest(p_valid_to, lower(valid) + interval '1 microsecond'), '[)'),
         superseded_at = now()
   where id = p_assertion_id returning * into v;
  if p_observation_id is not null then
    insert into memory.assertion_sources (assertion_id, observation_id) values (v.id, p_observation_id)
    on conflict do nothing;
  end if;
  return v;
end $$;

-- Mark a value as wrong (not merely no longer true). It leaves the current view and stops blocking others.
create or replace function memory.deprecate_fact(p_assertion_id uuid, p_asserted_by text) returns memory.assertions
language sql as $$
  update memory.assertions set rank = 'deprecated', superseded_at = coalesce(superseded_at, now())
  where id = p_assertion_id returning *
$$;

create or replace function memory.confirm_fact(p_assertion_id uuid, p_observation_id bigint default null) returns memory.assertions
language plpgsql as $$
declare
  v memory.assertions;
begin
  update memory.assertions set last_confirmed_at = now(), strength = strength + 1
   where id = p_assertion_id and upper_inf(valid) returning * into v;
  if not found then
    raise exception 'assertion % is not open', p_assertion_id;
  end if;
  if p_observation_id is not null then
    insert into memory.assertion_sources (assertion_id, observation_id) values (v.id, p_observation_id)
    on conflict do nothing;
  end if;
  return v;
end $$;

create or replace function memory.assert_relationship(
  p_subject_id uuid, p_relation text, p_object_id uuid, p_asserted_by text,
  p_properties jsonb default '{}'::jsonb, p_valid_from timestamptz default now(),
  p_confidence real default 1.0, p_level text default 'stated', p_observation_id bigint default null
) returns memory.relationships language plpgsql as $$
declare
  v_rel  memory.relations;
  v_open memory.relationships;
  v_new  memory.relationships;
  v_next timestamptz;
begin
  select * into v_rel from memory.relations where name = p_relation;
  if not found then
    raise exception 'relation % is not registered; register it first', p_relation;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_subject_id::text || '|' || p_relation, 0));

  if v_rel.cardinality = 'single' then
    select * into v_open from memory.relationships
     where subject_id = p_subject_id and relation = p_relation and upper_inf(valid) and rank <> 'deprecated'
     for update;
  else
    select * into v_open from memory.relationships
     where subject_id = p_subject_id and relation = p_relation and object_id = p_object_id
       and upper_inf(valid) and rank <> 'deprecated'
     for update;
  end if;

  if found and v_open.object_id = p_object_id then
    update memory.relationships
       set last_confirmed_at = now(), confidence = greatest(confidence, p_confidence),
           properties = properties || p_properties
     where id = v_open.id returning * into v_new;
    return v_new;
  end if;

  if found and p_valid_from >= lower(v_open.valid) then
    update memory.relationships
       set valid = tstzrange(lower(valid), greatest(p_valid_from, lower(valid) + interval '1 microsecond'), '[)'),
           superseded_at = now()
     where id = v_open.id;
    insert into memory.relationships (subject_id, relation, object_id, properties, valid, confidence, level, asserted_by, source_observation_id)
    values (p_subject_id, p_relation, p_object_id, p_properties, tstzrange(p_valid_from, null, '[)'),
            p_confidence, p_level, p_asserted_by, p_observation_id)
    returning * into v_new;
    update memory.relationships set superseded_by = v_new.id where id = v_open.id;
  else
    if v_rel.cardinality = 'single' then
      if exists (select 1 from memory.relationships
                  where subject_id = p_subject_id and relation = p_relation and rank <> 'deprecated'
                    and valid @> p_valid_from) then
        raise exception 'a % relationship already covers %; retract or deprecate it before recording history',
          p_relation, p_valid_from;
      end if;
      select min(lower(valid)) into v_next from memory.relationships
       where subject_id = p_subject_id and relation = p_relation and rank <> 'deprecated'
         and lower(valid) > p_valid_from;
    else
      if exists (select 1 from memory.relationships
                  where subject_id = p_subject_id and relation = p_relation and object_id = p_object_id
                    and rank <> 'deprecated' and valid @> p_valid_from) then
        raise exception 'that % relationship already covers %; retract or deprecate it before recording history',
          p_relation, p_valid_from;
      end if;
      select min(lower(valid)) into v_next from memory.relationships
       where subject_id = p_subject_id and relation = p_relation and object_id = p_object_id
         and rank <> 'deprecated' and lower(valid) > p_valid_from;
    end if;
    insert into memory.relationships (subject_id, relation, object_id, properties, valid, confidence, level, asserted_by, source_observation_id)
    values (p_subject_id, p_relation, p_object_id, p_properties, tstzrange(p_valid_from, v_next, '[)'),
            p_confidence, p_level, p_asserted_by, p_observation_id)
    returning * into v_new;
  end if;
  return v_new;
end $$;

create or replace function memory.retract_relationship(
  p_relationship_id uuid, p_asserted_by text, p_valid_to timestamptz default now()
) returns memory.relationships language plpgsql as $$
declare
  v memory.relationships;
begin
  select * into v from memory.relationships where id = p_relationship_id for update;
  if not found or not upper_inf(v.valid) then
    raise exception 'relationship % is not open', p_relationship_id;
  end if;
  update memory.relationships
     set valid = tstzrange(lower(valid), greatest(p_valid_to, lower(valid) + interval '1 microsecond'), '[)'),
         superseded_at = now()
   where id = p_relationship_id returning * into v;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Entities: find, create, merge.
-- ---------------------------------------------------------------------------

-- Exact alias matches first, then trigram candidates. Callers decide what to do below a high score.
create or replace function memory.find_entity(p_name text, p_type text default null, p_limit integer default 5)
returns table (entity_id uuid, name text, type text, score real, method text)
language sql stable
set search_path = memory, extensions, public
as $$
  with candidates as (
    select e.id, e.name, e.type, 1.0::real as score, 'alias'::text as method
      from memory.entity_aliases a
      join memory.entities e on e.id = a.entity_id
     where a.alias_norm = lower(btrim(p_name)) and e.merged_into is null
       and (p_type is null or e.type = p_type)
    union all
    select e.id, e.name, e.type, similarity(e.name, p_name), 'trigram'
      from memory.entities e
     where e.merged_into is null and (p_type is null or e.type = p_type)
       and e.name % p_name
  )
  select distinct on (id) id, name, type, score, method
    from candidates
   order by id, score desc
   limit p_limit
$$;

-- Create an entity unless one with this exact name or alias already exists (same type).
create or replace function memory.upsert_entity(
  p_type text, p_name text, p_created_by text,
  p_description text default null, p_aliases text[] default '{}',
  p_observation_id bigint default null
) returns memory.entities language plpgsql as $$
declare
  v memory.entities;
  a text;
begin
  select e.* into v from memory.entity_aliases al join memory.entities e on e.id = al.entity_id
   where al.alias_norm = lower(btrim(p_name)) and e.type = p_type and e.merged_into is null
   limit 1;
  if not found then
    select * into v from memory.entities
     where type = p_type and lower(name) = lower(btrim(p_name)) and merged_into is null;
  end if;
  if not found then
    insert into memory.entities (type, name, description, created_by, source_observation_id)
    values (p_type, btrim(p_name), p_description, p_created_by, p_observation_id)
    returning * into v;
  elsif p_description is not null and v.description is null then
    update memory.entities set description = p_description where id = v.id returning * into v;
  end if;
  insert into memory.entity_aliases (entity_id, alias, source) values (v.id, btrim(p_name), p_created_by)
  on conflict do nothing;
  foreach a in array p_aliases loop
    insert into memory.entity_aliases (entity_id, alias, source) values (v.id, btrim(a), p_created_by)
    on conflict do nothing;
  end loop;
  return v;
end $$;

-- Fold one entity into another. Fails if both hold a live value for the same single-valued attribute;
-- resolve that first, then merge.
create or replace function memory.merge_entities(p_from uuid, p_into uuid, p_by text) returns memory.entities
language plpgsql as $$
declare
  v memory.entities;
begin
  if p_from = p_into then
    raise exception 'cannot merge an entity into itself';
  end if;
  perform set_config('memory.merging', 'on', true);   -- transaction-local; lets the immutability guards allow repointing
  update memory.assertions set entity_id = p_into where entity_id = p_from;
  update memory.relationships set subject_id = p_into where subject_id = p_from;
  update memory.relationships set object_id = p_into where object_id = p_from;
  update memory.plans set entity_id = p_into where entity_id = p_from;
  update memory.rules set entity_id = p_into where entity_id = p_from;
  update memory.connectors set entity_id = p_into where entity_id = p_from;
  insert into memory.entity_aliases (entity_id, alias, source, confidence)
    select p_into, alias, source, confidence from memory.entity_aliases where entity_id = p_from
    on conflict do nothing;
  update memory.entities set merged_into = p_into, retired_at = now() where id = p_from;
  perform memory.record_observation('consolidation', 'merge', 'merged entity ' || p_from || ' into ' || p_into,
                                    jsonb_build_object('from', p_from, 'into', p_into), null, p_by);
  select * into v from memory.entities where id = p_into;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Access. Only the service role reaches this schema; every table has RLS on with no policies.
-- ---------------------------------------------------------------------------

alter table memory.conversations     enable row level security;
alter table memory.messages          enable row level security;
alter table memory.observations      enable row level security;
alter table memory.entities          enable row level security;
alter table memory.entity_aliases    enable row level security;
alter table memory.entity_embeddings enable row level security;
alter table memory.attributes        enable row level security;
alter table memory.relations         enable row level security;
alter table memory.assertions        enable row level security;
alter table memory.assertion_sources enable row level security;
alter table memory.relationships     enable row level security;
alter table memory.plans             enable row level security;
alter table memory.rules             enable row level security;
alter table memory.questions         enable row level security;
alter table memory.connectors        enable row level security;

grant usage on schema memory to service_role;
grant all on all tables in schema memory to service_role;
grant all on all sequences in schema memory to service_role;
grant execute on all functions in schema memory to service_role;
alter default privileges in schema memory grant all on tables to service_role;
alter default privileges in schema memory grant all on sequences to service_role;
alter default privileges in schema memory grant execute on functions to service_role;
