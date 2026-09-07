-- The latest assertion is current.
--
-- A new value with a start earlier than the current value's start used to be
-- filed as history. In conversation that is backwards: "I've been at Globex
-- since August", said after "I work at Acme", means Globex is current and the
-- Acme claim was wrong. So: a new assertion is always current. Rows it
-- overlaps are closed where it begins if they started earlier, and deprecated
-- if they started later. Narrating the past is explicit: pass p_valid_to.

drop function memory.assert_fact(uuid, text, jsonb, text, timestamptz, real, text, bigint);
drop function memory.assert_relationship(uuid, text, uuid, text, jsonb, timestamptz, real, text, bigint);

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
  r       memory.assertions;
begin
  select * into v_attr from memory.attributes where name = p_attribute;
  if not found then
    raise exception 'attribute % is not registered; register it first', p_attribute;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_entity_id::text || '|' || p_attribute, 0));

  -- the same value, already current: re-confirm
  select * into v_open from memory.assertions
   where entity_id = p_entity_id and attribute = p_attribute and upper_inf(valid) and rank <> 'deprecated'
     and value_hash = v_hash
   for update;
  if found and p_valid_to is null then
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
   where entity_id = p_entity_id and attribute = p_attribute and superseded_at is not null and superseded_by is null
     and id <> v_new.id and (v_attr.cardinality = 'single' or value_hash = v_hash);
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
  r       memory.relationships;
begin
  select * into v_rel from memory.relations where name = p_relation;
  if not found then
    raise exception 'relation % is not registered; register it first', p_relation;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_subject_id::text || '|' || p_relation, 0));

  select * into v_open from memory.relationships
   where subject_id = p_subject_id and relation = p_relation and object_id = p_object_id
     and upper_inf(valid) and rank <> 'deprecated'
   for update;
  if found and p_valid_to is null then
    update memory.relationships
       set last_confirmed_at = now(), confidence = greatest(confidence, p_confidence), properties = properties || p_properties
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
   where subject_id = p_subject_id and relation = p_relation and superseded_at is not null and superseded_by is null
     and id <> v_new.id and (v_rel.cardinality = 'single' or object_id = p_object_id);
  return v_new;
end $$;

grant execute on all functions in schema memory to service_role;
