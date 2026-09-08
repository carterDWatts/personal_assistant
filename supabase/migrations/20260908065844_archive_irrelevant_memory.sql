create table memory.archived_records (
 kind text not null check(kind in ('assertions','relationships')),
 id uuid not null,
 reason text not null,
 message_id bigint references memory.messages(id),
 created_at timestamptz not null default now(),
 primary key(kind,id)
);
alter table memory.archived_records enable row level security;
grant select,insert,delete on memory.archived_records to service_role;
create trigger context_changed after insert or update or delete on memory.archived_records for each statement execute function memory.invalidate_context();
create or replace view memory.current_assertions as
select a.id, a.entity_id, e.type as entity_type, e.name as entity_name,
       a.attribute, a.value, lower(a.valid) as valid_from,
       a.confidence, a.level, a.asserted_by, a.recorded_at, a.last_confirmed_at, a.strength,
       t.importance, t.stale_after,
       (t.stale_after is not null and a.last_confirmed_at + t.stale_after < now()) as stale
from memory.assertions a
join memory.entities e on e.id = a.entity_id
join memory.attributes t on t.name = a.attribute
where a.valid @> now() and a.rank <> 'deprecated' and e.merged_into is null and e.retired_at is null and not exists(select 1 from memory.archived_records x where x.kind='assertions' and x.id=a.id);
comment on view memory.current_assertions is 'What is true now. Stale rows are due for re-verification.';

create or replace view memory.current_relationships as
select r.id, r.subject_id, s.type as subject_type, s.name as subject_name,
       r.relation, r.object_id, o.type as object_type, o.name as object_name,
       r.properties, lower(r.valid) as valid_from,
       r.confidence, r.level, r.asserted_by, r.recorded_at, r.last_confirmed_at
from memory.relationships r
join memory.entities s on s.id = r.subject_id
join memory.entities o on o.id = r.object_id
where r.valid @> now() and r.rank <> 'deprecated' and s.merged_into is null and o.merged_into is null and s.retired_at is null and o.retired_at is null and not exists(select 1 from memory.archived_records x where x.kind='relationships' and x.id=r.id);
comment on view memory.current_relationships is 'Which entities are linked right now.';


alter view memory.current_assertions set (security_invoker=true);
alter view memory.current_relationships set (security_invoker=true);
alter table assistant.attention add column thread_key text;
create unique index attention_thread on assistant.attention(source,thread_key) where thread_key is not null;
