-- Use actual validity intervals and link only rows changed by this write.
create or replace view memory.current_assertions as
select a.id, a.entity_id, e.type as entity_type, e.name as entity_name,
       a.attribute, a.value, lower(a.valid) as valid_from,
       a.confidence, a.level, a.asserted_by, a.recorded_at, a.last_confirmed_at, a.strength,
       t.importance, t.stale_after,
       (t.stale_after is not null and a.last_confirmed_at + t.stale_after < now()) as stale
from memory.assertions a
join memory.entities e on e.id = a.entity_id
join memory.attributes t on t.name = a.attribute
where a.valid @> now() and a.rank <> 'deprecated' and e.merged_into is null and e.retired_at is null;
comment on view memory.current_assertions is 'What is true now. Stale rows are due for re-verification.';

create or replace view memory.current_relationships as
select r.id, r.subject_id, s.type as subject_type, s.name as subject_name,
       r.relation, r.object_id, o.type as object_type, o.name as object_name,
       r.properties, lower(r.valid) as valid_from,
       r.confidence, r.level, r.asserted_by, r.recorded_at, r.last_confirmed_at
from memory.relationships r
join memory.entities s on s.id = r.subject_id
join memory.entities o on o.id = r.object_id
where r.valid @> now() and r.rank <> 'deprecated' and s.merged_into is null and o.merged_into is null and s.retired_at is null and o.retired_at is null;
comment on view memory.current_relationships is 'Which entities are linked right now.';


create or replace function memory.assert_fact(
  p_entity_id uuid, p_attribute text, p_value jsonb, p_asserted_by text,
  p_valid_from timestamptz default now(), p_confidence real default 1.0,
  p_level text default 'stated', p_observation_id bigint default null,
  p_valid_to timestamptz default null
) returns memory.assertions language plpgsql as $$
declare
  v_attr  memory.attributes;
  v_open  memory.assertions;
  v_new   memory.assertions;
  v_hash  text := md5(p_value::text);
  v_range tstzrange;
  v_changed uuid[] := array[]::uuid[];
  r       memory.assertions;
begin
  select * into v_attr from memory.attributes where name = p_attribute;
  if not found then
    raise exception 'attribute % is not registered; register it first', p_attribute;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_entity_id::text || '|' || p_attribute, 0));

  if p_valid_from is null then raise exception 'valid_from is required'; end if;
  if p_valid_to is null and p_level <> 'stated' and exists (
    select 1 from memory.assertions
    where entity_id = p_entity_id and attribute = p_attribute and rank <> 'deprecated'
      and (v_attr.cardinality = 'single' or value_hash = v_hash) and valid && tstzrange(p_valid_from, null, '[)')
      and ((p_level = 'inferred' and level <> 'inferred') or lower(valid) > p_valid_from)
  ) then raise exception 'conflicting evidence requires confirmation or an explicit history interval'; end if;

  -- the same value, already current: re-confirm
  select * into v_open from memory.assertions
   where entity_id = p_entity_id and attribute = p_attribute and upper_inf(valid) and rank <> 'deprecated'
     and value_hash = v_hash
   for update;
  if found and p_valid_to is null and v_open.valid @> p_valid_from then
    update memory.assertions
       set last_confirmed_at = now(), confidence = greatest(confidence, p_confidence), strength = strength + 1
     where id = v_open.id returning * into v_new;
    if p_observation_id is not null then
      insert into memory.assertion_sources (assertion_id, observation_id) values (v_new.id, p_observation_id)
      on conflict do nothing;
    end if;
    return v_new;
  end if;

  -- explicit history: a closed interval that must fit a gap
  if p_valid_to is not null then
    if p_valid_to <= p_valid_from then
      raise exception 'valid_to must be after valid_from';
    end if;
    v_range := tstzrange(p_valid_from, p_valid_to, '[)');
    if exists (select 1 from memory.assertions
                where entity_id = p_entity_id and attribute = p_attribute and rank <> 'deprecated'
                  and (v_attr.cardinality = 'single' or value_hash = v_hash) and valid && v_range) then
      raise exception 'history for % from % to % overlaps a known value; retract or deprecate it first',
        p_attribute, p_valid_from, p_valid_to;
    end if;
    insert into memory.assertions (entity_id, attribute, value, valid, confidence, level, asserted_by, source_observation_id)
    values (p_entity_id, p_attribute, p_value, v_range, p_confidence, p_level, p_asserted_by, p_observation_id)
    returning * into v_new;
    if p_observation_id is not null then
      insert into memory.assertion_sources (assertion_id, observation_id) values (v_new.id, p_observation_id);
    end if;
    return v_new;
  end if;

  -- making a new value current: whatever it overlaps ends where it begins, or was wrong
  v_range := tstzrange(p_valid_from, null, '[)');
  for r in select * from memory.assertions
            where entity_id = p_entity_id and attribute = p_attribute and rank <> 'deprecated'
              and (v_attr.cardinality = 'single' or value_hash = v_hash) and valid && v_range
            for update
  loop
    v_changed := array_append(v_changed, r.id);
    if lower(r.valid) < p_valid_from then
      update memory.assertions set valid = tstzrange(lower(valid), p_valid_from, '[)'), superseded_at = now() where id = r.id;
    else
      update memory.assertions set rank = 'deprecated', superseded_at = now() where id = r.id;
    end if;
  end loop;
  insert into memory.assertions (entity_id, attribute, value, valid, confidence, level, asserted_by, source_observation_id)
  values (p_entity_id, p_attribute, p_value, v_range, p_confidence, p_level, p_asserted_by, p_observation_id)
  returning * into v_new;
  update memory.assertions set superseded_by = v_new.id
   where id = any(v_changed);
  if p_observation_id is not null then
    insert into memory.assertion_sources (assertion_id, observation_id) values (v_new.id, p_observation_id);
  end if;
  return v_new;
end $$;

create or replace function memory.assert_relationship(
  p_subject_id uuid, p_relation text, p_object_id uuid, p_asserted_by text,
  p_properties jsonb default '{}'::jsonb, p_valid_from timestamptz default now(),
  p_confidence real default 1.0, p_level text default 'stated', p_observation_id bigint default null,
  p_valid_to timestamptz default null
) returns memory.relationships language plpgsql as $$
declare
  v_rel   memory.relations;
  v_open  memory.relationships;
  v_new   memory.relationships;
  v_range tstzrange;
  v_changed uuid[] := array[]::uuid[];
  r       memory.relationships;
begin
  select * into v_rel from memory.relations where name = p_relation;
  if not found then
    raise exception 'relation % is not registered; register it first', p_relation;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_subject_id::text || '|' || p_relation, 0));

  if p_valid_from is null then raise exception 'valid_from is required'; end if;
  if p_valid_to is null and p_level <> 'stated' and exists (
    select 1 from memory.relationships
    where subject_id = p_subject_id and relation = p_relation and rank <> 'deprecated'
      and (v_rel.cardinality = 'single' or object_id = p_object_id) and valid && tstzrange(p_valid_from, null, '[)')
      and ((p_level = 'inferred' and level <> 'inferred') or lower(valid) > p_valid_from)
  ) then raise exception 'conflicting evidence requires confirmation or an explicit history interval'; end if;

  select * into v_open from memory.relationships
   where subject_id = p_subject_id and relation = p_relation and object_id = p_object_id
     and upper_inf(valid) and rank <> 'deprecated'
   for update;
  if found then
    p_properties := v_open.properties || p_properties;
  end if;
  if found and p_valid_to is null and v_open.valid @> p_valid_from
     and v_open.properties = p_properties then
    update memory.relationships
       set last_confirmed_at = now(), confidence = greatest(confidence, p_confidence)
     where id = v_open.id returning * into v_new;
    return v_new;
  end if;

  if p_valid_to is not null then
    if p_valid_to <= p_valid_from then
      raise exception 'valid_to must be after valid_from';
    end if;
    v_range := tstzrange(p_valid_from, p_valid_to, '[)');
    if exists (select 1 from memory.relationships
                where subject_id = p_subject_id and relation = p_relation and rank <> 'deprecated'
                  and (v_rel.cardinality = 'single' or object_id = p_object_id) and valid && v_range) then
      raise exception 'history for % from % to % overlaps a known relationship; retract or deprecate it first',
        p_relation, p_valid_from, p_valid_to;
    end if;
    insert into memory.relationships (subject_id, relation, object_id, properties, valid, confidence, level, asserted_by, source_observation_id)
    values (p_subject_id, p_relation, p_object_id, p_properties, v_range, p_confidence, p_level, p_asserted_by, p_observation_id)
    returning * into v_new;
    return v_new;
  end if;

  v_range := tstzrange(p_valid_from, null, '[)');
  for r in select * from memory.relationships
            where subject_id = p_subject_id and relation = p_relation and rank <> 'deprecated'
              and (v_rel.cardinality = 'single' or object_id = p_object_id) and valid && v_range
            for update
  loop
    v_changed := array_append(v_changed, r.id);
    if lower(r.valid) < p_valid_from then
      update memory.relationships set valid = tstzrange(lower(valid), p_valid_from, '[)'), superseded_at = now() where id = r.id;
    else
      update memory.relationships set rank = 'deprecated', superseded_at = now() where id = r.id;
    end if;
  end loop;
  insert into memory.relationships (subject_id, relation, object_id, properties, valid, confidence, level, asserted_by, source_observation_id)
  values (p_subject_id, p_relation, p_object_id, p_properties, v_range, p_confidence, p_level, p_asserted_by, p_observation_id)
  returning * into v_new;
  update memory.relationships set superseded_by = v_new.id
   where id = any(v_changed);
  return v_new;
end $$;

grant execute on all functions in schema memory to service_role;

create or replace function memory.retract_fact(
  p_assertion_id uuid, p_asserted_by text, p_valid_to timestamptz default now(), p_observation_id bigint default null
) returns memory.assertions language plpgsql as $$
declare
  v memory.assertions;
begin
  select * into v from memory.assertions where id = p_assertion_id for update;
  if not found or v.rank = 'deprecated' or not (v.valid @> now()) then
    raise exception 'assertion % is not open', p_assertion_id;
  end if;
  update memory.assertions
     set valid = tstzrange(lower(valid), greatest(p_valid_to, lower(valid) + interval '1 microsecond'), '[)'),
         rank = case when p_valid_to <= lower(valid) then 'deprecated' else rank end,
         superseded_at = now()
   where id = p_assertion_id returning * into v;
  if p_observation_id is not null then
    insert into memory.assertion_sources (assertion_id, observation_id) values (v.id, p_observation_id)
    on conflict do nothing;
  end if;
  return v;
end $$;


create or replace function memory.retract_relationship(
  p_relationship_id uuid, p_asserted_by text, p_valid_to timestamptz default now()
) returns memory.relationships language plpgsql as $$
declare
  v memory.relationships;
begin
  select * into v from memory.relationships where id = p_relationship_id for update;
  if not found or v.rank = 'deprecated' or not (v.valid @> now()) then
    raise exception 'relationship % is not open', p_relationship_id;
  end if;
  update memory.relationships
     set valid = tstzrange(lower(valid), greatest(p_valid_to, lower(valid) + interval '1 microsecond'), '[)'),
         rank = case when p_valid_to <= lower(valid) then 'deprecated' else rank end,
         superseded_at = now()
   where id = p_relationship_id returning * into v;
  return v;
end $$;


create or replace function memory.confirm_fact(p_assertion_id uuid, p_observation_id bigint default null) returns memory.assertions
language plpgsql as $$
declare
  v memory.assertions;
begin
  update memory.assertions set last_confirmed_at = now(), strength = strength + 1
   where id = p_assertion_id and valid @> now() and rank <> 'deprecated' returning * into v;
  if not found then
    raise exception 'assertion % is not open', p_assertion_id;
  end if;
  if p_observation_id is not null then
    insert into memory.assertion_sources (assertion_id, observation_id) values (v.id, p_observation_id)
    on conflict do nothing;
  end if;
  return v;
end $$;


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
  select id, name, type, score, method from (
    select distinct on (id) * from candidates order by id, score desc
  ) ranked order by score desc, name, id limit greatest(1, least(p_limit, 50))
$$;


create or replace function memory.upsert_entity(
  p_type text, p_name text, p_created_by text,
  p_description text default null, p_aliases text[] default '{}',
  p_observation_id bigint default null
) returns memory.entities language plpgsql as $$
declare
  v memory.entities;
  a text;
begin
  if btrim(p_name) = '' or btrim(p_type) = '' then raise exception 'name and type are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('entity:' || p_type || ':' || lower(btrim(p_name)), 0));
  if (select count(*) from memory.entity_aliases al join memory.entities e on e.id = al.entity_id
      where al.alias_norm = lower(btrim(p_name)) and e.type = p_type and e.merged_into is null) > 1 then
    raise exception 'ambiguous alias; choose an entity explicitly';
  end if;
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


create or replace function memory.merge_entities(p_from uuid, p_into uuid, p_by text) returns memory.entities
language plpgsql as $$
declare
  v memory.entities;
begin
  if p_from = p_into then
    raise exception 'cannot merge an entity into itself';
  end if;
  perform id from memory.entities where id in (p_from, p_into) order by id for update;
  if (select count(*) from memory.entities where id in (p_from, p_into) and merged_into is null and retired_at is null) <> 2 then
    raise exception 'merge requires two active entities';
  end if;
  if exists (select 1 from memory.relationships where (subject_id = p_from and object_id = p_into) or (subject_id = p_into and object_id = p_from)) then
    raise exception 'merge would create a self relationship; resolve it first';
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
  perform set_config('memory.merging', 'off', true);
  return v;
end $$;


-- Preserve the database's previous belief when validity, rank or properties change.
create table memory.revisions (
  id bigint generated always as identity primary key,
  table_name text not null,
  row_id uuid not null,
  recorded_at timestamptz not null default clock_timestamp(),
  previous jsonb not null,
  replacement jsonb not null
);
alter table memory.revisions enable row level security;
create index revisions_row on memory.revisions(table_name, row_id, recorded_at);
create function memory.audit_revision() returns trigger language plpgsql as $$
begin
  if old is distinct from new then
    insert into memory.revisions(table_name,row_id,previous,replacement)
    values (tg_table_name,old.id,to_jsonb(old),to_jsonb(new));
  end if;
  return new;
end $$;
create trigger assertions_audit after update on memory.assertions for each row execute function memory.audit_revision();
create trigger relationships_audit after update on memory.relationships for each row execute function memory.audit_revision();
create function memory.protect_revision() returns trigger language plpgsql as $$
begin raise exception 'revisions are append-only'; end $$;
create trigger revisions_immutable before update or delete on memory.revisions for each row execute function memory.protect_revision();

-- Views must not bypass the caller's row policies.
alter view memory.current_assertions set (security_invoker=true);
alter view memory.current_relationships set (security_invoker=true);
alter view memory.assertion_history set (security_invoker=true);
alter view memory.transitions set (security_invoker=true);
revoke execute on all functions in schema memory from public;
grant select,insert on memory.revisions to service_role;
grant usage,select on all sequences in schema memory to service_role;
grant execute on all functions in schema memory to service_role;
