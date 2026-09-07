-- Reconfirming a relationship must retain the new source as well as the original one.
create table memory.relationship_sources (
  relationship_id uuid not null references memory.relationships(id),
  observation_id bigint not null references memory.observations(id),
  added_at timestamptz not null default now(),
  primary key (relationship_id, observation_id)
);
alter table memory.relationship_sources enable row level security;
insert into memory.relationship_sources(relationship_id, observation_id)
select id, source_observation_id from memory.relationships where source_observation_id is not null;
grant select, insert on memory.relationship_sources to service_role;

create or replace view memory.transitions as
select o.entity_id, e.name as entity_name, o.attribute,
       o.value as from_value, n.value as to_value,
       lower(o.valid) as from_since, upper(o.valid) as changed_at,
       o.id as from_assertion_id, n.id as to_assertion_id
from memory.assertions o
join memory.assertions n on n.id = o.superseded_by
join memory.entities e on e.id = o.entity_id
where o.rank <> 'deprecated' and n.rank <> 'deprecated'
  and o.cardinality = 'single' and n.cardinality = 'single'
  and upper(o.valid) = lower(n.valid) and upper(o.valid) <= now();
alter view memory.transitions set (security_invoker=true);

-- Changing a used predicate's shape would reinterpret existing rows.
create function memory.protect_predicate() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'attributes' then
    if (new.cardinality <> old.cardinality or new.value_type <> old.value_type)
       and exists (select 1 from memory.assertions where attribute = old.name) then
      raise exception 'used attributes cannot change type or cardinality';
    end if;
  elsif new.cardinality <> old.cardinality
        and exists (select 1 from memory.relationships where relation = old.name) then
    raise exception 'used relations cannot change cardinality';
  end if;
  return new;
end $$;
create trigger attributes_shape before update on memory.attributes for each row execute function memory.protect_predicate();
create trigger relations_shape before update on memory.relations for each row execute function memory.protect_predicate();
revoke execute on function memory.protect_predicate() from public;
alter default privileges in schema memory revoke execute on functions from public;

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
    if p_observation_id is not null then
      insert into memory.relationship_sources(relationship_id,observation_id) values (v_new.id,p_observation_id) on conflict do nothing;
    end if;
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
    if p_observation_id is not null then
      insert into memory.relationship_sources(relationship_id,observation_id) values (v_new.id,p_observation_id) on conflict do nothing;
    end if;
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
  if p_observation_id is not null then
    insert into memory.relationship_sources(relationship_id,observation_id) values (v_new.id,p_observation_id) on conflict do nothing;
  end if;
  return v_new;
end $$;

