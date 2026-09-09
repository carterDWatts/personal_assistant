-- Dated observations complement time-varying facts. Totals are queries, not beliefs.
create table memory.records (
 id uuid primary key default gen_random_uuid(),
 entity_id uuid references memory.entities(id),
 kind text not null check(length(kind) between 1 and 80),
 day date not null,
 slot text not null check(length(slot) between 1 and 160),
 status text not null check(status in ('actual','planned','retracted')),
 quantities jsonb not null default '{}' check(jsonb_typeof(quantities)='object' and octet_length(quantities::text)<=16000),
 details jsonb not null default '{}' check(jsonb_typeof(details)='object' and octet_length(details::text)<=16000),
 message_id bigint not null references memory.messages(id),
 version integer not null default 1 check(version>0),
 recorded_at timestamptz not null default clock_timestamp(),
 unique(kind,day,slot)
);
create index records_day on memory.records(day,kind) where status='actual';
create index records_entity on memory.records(entity_id);
create index records_message on memory.records(message_id);
create table memory.record_revisions (
 record_id uuid not null references memory.records(id),
 version integer not null,
 snapshot jsonb not null,
 primary key(record_id,version)
);
create function memory.record_revision() returns trigger language plpgsql set search_path='' as $$
declare q jsonb;
begin
 for q in select value from jsonb_each(new.quantities) loop
  if jsonb_typeof(q) is distinct from 'object' or jsonb_typeof(q->'value') is distinct from 'number'
     or jsonb_typeof(q->'unit') is distinct from 'string' or length(q->>'unit') not between 1 and 40
     or coalesce(q->>'basis','') not in ('measured','label','estimate') then
   raise exception 'Quantities require a numeric value, unit and evidence basis';
  end if;
 end loop;
 if tg_op='UPDATE' then
  if new.id<>old.id or new.message_id<old.message_id then raise exception 'An older source cannot replace a newer record'; end if;
  new.version=old.version+1;
 end if;
 new.recorded_at=clock_timestamp();
 insert into memory.record_revisions values(new.id,new.version,to_jsonb(new));
 return new;
end $$;
-- Deferred FK permits the first revision to be written by the insert trigger.
alter table memory.record_revisions alter constraint record_revisions_record_id_fkey deferrable initially deferred;
create trigger record_revision before insert or update on memory.records for each row execute function memory.record_revision();
create function memory.preserve_record_history() returns trigger language plpgsql set search_path='' as $$
begin raise exception 'Record revisions are immutable'; end $$;
create trigger preserve_record_history before update or delete on memory.record_revisions for each row execute function memory.preserve_record_history();

create table memory.routine_progress (
 conversation_id uuid primary key references memory.conversations(id),
 steps jsonb not null check(jsonb_typeof(steps)='array' and jsonb_array_length(steps) between 1 and 30),
 rule_ids bigint[] not null default '{}',
 position integer not null default 0 check(position>=0 and position<=jsonb_array_length(steps)),
 updated_at timestamptz not null default clock_timestamp()
);
alter table memory.memory_jobs add column receipt jsonb;
alter table memory.memory_jobs add column diagnostics jsonb not null default '[]';

alter table memory.records enable row level security;
alter table memory.record_revisions enable row level security;
alter table memory.routine_progress enable row level security;
revoke all on memory.records,memory.record_revisions,memory.routine_progress from public,anon,authenticated;
grant select,insert,update on memory.records,memory.routine_progress to service_role;
grant select,insert on memory.record_revisions to service_role;
revoke all on function memory.record_revision(),memory.preserve_record_history() from public;
create trigger records_context after insert or update or delete on memory.records for each statement execute function memory.invalidate_context();
