-- Reasons remain attached to the record even after it leaves current memory.
alter table memory.assertions add column resolution_reason text;
alter table memory.relationships add column resolution_reason text;
create table memory.derivations (
 id bigint generated always as identity primary key,
 assertion_id uuid references memory.assertions(id) on delete cascade,
 relationship_id uuid references memory.relationships(id) on delete cascade,
 source_assertion_id uuid references memory.assertions(id),
 source_relationship_id uuid references memory.relationships(id),
 rationale text not null,
 check (num_nonnulls(assertion_id,relationship_id)=1),
 check (num_nonnulls(source_assertion_id,source_relationship_id)=1)
);
alter table memory.derivations enable row level security;
grant select,insert on memory.derivations to service_role;
grant usage,select on sequence memory.derivations_id_seq to service_role;
create index derivations_fact_source on memory.derivations(source_assertion_id);
create index derivations_relationship_source on memory.derivations(source_relationship_id);

-- A changed premise invalidates derived beliefs immediately, not at tomorrow's cleanup.
create function memory.invalidate_derivations() returns trigger language plpgsql security invoker set search_path='' as $$
declare d record;
begin
 if old.valid is not distinct from new.valid and old.rank is not distinct from new.rank then return new; end if;
 for d in select * from memory.derivations where
 (tg_table_name='assertions' and source_assertion_id=new.id) or
 (tg_table_name='relationships' and source_relationship_id=new.id)
 loop
  if d.assertion_id is not null then
   update memory.assertions set rank='deprecated',superseded_at=now(),resolution_reason='Supporting evidence changed; inference requires review.' where id=d.assertion_id and level='inferred' and rank<>'deprecated';
  else
   update memory.relationships set rank='deprecated',superseded_at=now(),resolution_reason='Supporting evidence changed; inference requires review.' where id=d.relationship_id and level='inferred' and rank<>'deprecated';
  end if;
 end loop;
 return new;
end $$;
revoke all on function memory.invalidate_derivations() from public;
create trigger invalidate_derivations after update of valid,rank on memory.assertions for each row execute function memory.invalidate_derivations();
create trigger invalidate_derivations after update of valid,rank on memory.relationships for each row execute function memory.invalidate_derivations();
