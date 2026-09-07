-- Behavioral checks for the knowledge map. Runs against a fresh database after the migration.
-- Every block either succeeds or raises; a raised exception fails the run.
-- Blocks that expect an error catch it and check the message.

set search_path = memory, extensions, public;

-- registries -------------------------------------------------------------------
insert into memory.attributes (name, description, value_type, cardinality, stale_after, importance, created_by) values
  ('parked_at', 'where the car is', 'text', 'single', interval '3 days', 3, 'test'),
  ('hobby', 'a thing they do for fun', 'text', 'multi', null, 1, 'test'),
  ('mileage', 'odometer reading', 'number', 'single', interval '90 days', 2, 'test'),
  ('birthday', null, 'date', 'single', null, 2, 'test');
insert into memory.relations (name, cardinality, inverse, created_by) values
  ('employed_by', 'single', 'employs', 'test'),
  ('friends_with', 'multi', 'friends_with', 'test');

-- entities ------------------------------------------------------------------------
do $$
declare
  car memory.entities; car2 memory.entities; me memory.entities; acme memory.entities; sam memory.entities;
  hits int;
begin
  car := memory.upsert_entity('vehicle', 'Porsche', 'test', 'the 911', array['the car', 'my porsche']);
  car2 := memory.upsert_entity('vehicle', 'the car', 'test');
  if car.id <> car2.id then raise exception 'FAIL alias lookup should return the same entity'; end if;
  me := memory.upsert_entity('person', 'Carter', 'test');
  acme := memory.upsert_entity('organization', 'Acme Corp', 'test');
  sam := memory.upsert_entity('person', 'Sam', 'test');
  select count(*) into hits from memory.find_entity('porshe', 'vehicle');
  if hits < 1 then raise exception 'FAIL trigram should find a misspelled name'; end if;
  select count(*) into hits from memory.find_entity('my porsche');
  if hits < 1 then raise exception 'FAIL alias should resolve'; end if;
end $$;

-- single-valued facts: confirm, supersede, history, transitions ----------------
do $$
declare
  car uuid := (select id from memory.entities where name = 'Porsche');
  obs bigint;
  a1 memory.assertions; a2 memory.assertions; a3 memory.assertions; a4 memory.assertions; a5 memory.assertions;
  n int;
begin
  obs := memory.record_observation('conversation', 'statement', 'car is on 5th street', null, null, 'test');
  a1 := memory.assert_fact(car, 'parked_at', '"5th street"', 'test', now() - interval '2 days', 1.0, 'stated', obs);
  a2 := memory.assert_fact(car, 'parked_at', '"5th street"', 'test', now() - interval '1 day', 0.8, 'stated', obs);
  if a1.id <> a2.id then raise exception 'FAIL same value should re-confirm, not insert'; end if;
  if a2.strength <> 2 then raise exception 'FAIL re-confirmation should reinforce strength'; end if;

  a3 := memory.assert_fact(car, 'parked_at', '"garage"', 'test', now(), 1.0, 'stated', obs);
  if a3.id = a1.id then raise exception 'FAIL new value should insert'; end if;
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'parked_at';
  if n <> 1 then raise exception 'FAIL exactly one current value, got %', n; end if;
  if (select value from memory.current_assertions where entity_id = car and attribute = 'parked_at') <> '"garage"' then
    raise exception 'FAIL current value should be garage';
  end if;
  if (select superseded_by from memory.assertions where id = a1.id) <> a3.id then
    raise exception 'FAIL old row should point at its replacement';
  end if;
  select count(*) into n from memory.transitions where entity_id = car and from_value = '"5th street"' and to_value = '"garage"';
  if n <> 1 then raise exception 'FAIL transition should be recorded'; end if;

  -- narrating the past is explicit: a closed interval that fits a gap
  a4 := memory.assert_fact(car, 'parked_at', '"airport lot"', 'test', now() - interval '10 days', 0.6, 'inferred', obs,
                           lower(a1.valid));
  if upper_inf(a4.valid) then raise exception 'FAIL explicit history must be closed'; end if;
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'parked_at';
  if n <> 1 then raise exception 'FAIL history must not change the current value'; end if;
  -- history that overlaps a known value is refused, not silently overlapped
  begin
    perform memory.assert_fact(car, 'parked_at', '"somewhere"', 'test', now() - interval '1 day', 0.6, 'inferred', obs, now());
    raise exception 'FAIL history over a known interval must be refused';
  exception when others then
    if position('overlaps' in sqlerrm) = 0 then raise; end if;
  end;
  -- a new current value that started before the current one: the current one was wrong, so it is deprecated
  a5 := memory.assert_fact(car, 'parked_at', '"driveway"', 'test', now() - interval '1 day', 1.0, 'stated', obs);
  if not upper_inf(a5.valid) then raise exception 'FAIL the latest assertion must be current'; end if;
  if (select rank from memory.assertions where id = a3.id) <> 'deprecated' then
    raise exception 'FAIL a value that started after the new one must be deprecated';
  end if;
  if upper((select valid from memory.assertions where id = a1.id)) <> lower(a5.valid) then
    raise exception 'FAIL a value that started before the new one must end where it begins';
  end if;
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'parked_at';
  if n <> 1 then raise exception 'FAIL exactly one current value after a backdated supersede, got %', n; end if;
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'parked_at';
  if n <> 1 then raise exception 'FAIL history insert must not change the current value'; end if;
  select count(*) into n from memory.assertion_history where entity_id = car and attribute = 'parked_at';
  if n <> 4 then raise exception 'FAIL expected four rows of history, got %', n; end if;
  select count(*) into n from memory.assertion_sources where assertion_id = a1.id;
  if n <> 1 then raise exception 'FAIL provenance should be recorded once per observation'; end if;
end $$;

-- multi-valued facts ----------------------------------------------------------------
do $$
declare
  me uuid := (select id from memory.entities where name = 'Carter');
  h1 memory.assertions; h2 memory.assertions; h3 memory.assertions;
  n int;
begin
  h1 := memory.assert_fact(me, 'hobby', '"climbing"', 'test');
  h2 := memory.assert_fact(me, 'hobby', '"wrenching"', 'test');
  h3 := memory.assert_fact(me, 'hobby', '"climbing"', 'test');
  if h1.id <> h3.id then raise exception 'FAIL same multi value should re-confirm'; end if;
  select count(*) into n from memory.current_assertions where entity_id = me and attribute = 'hobby';
  if n <> 2 then raise exception 'FAIL both hobbies should be current, got %', n; end if;
  perform memory.retract_fact(h1.id, 'test');
  select count(*) into n from memory.current_assertions where entity_id = me and attribute = 'hobby';
  if n <> 1 then raise exception 'FAIL retracted hobby should leave one current'; end if;
end $$;

-- typed values and registry enforcement --------------------------------------------
do $$
declare
  car uuid := (select id from memory.entities where name = 'Porsche');
  ok boolean := false;
begin
  perform memory.assert_fact(car, 'mileage', '84210', 'test');
  perform memory.assert_fact(car, 'birthday', '"1999-05-04"', 'test');
  begin
    perform memory.assert_fact(car, 'mileage', '"lots"', 'test');
  exception when others then
    ok := position('JSON number' in sqlerrm) > 0;
  end;
  if not ok then raise exception 'FAIL wrong value type must be rejected'; end if;
  ok := false;
  begin
    perform memory.assert_fact(car, 'color', '"red"', 'test');
  exception when others then
    ok := position('not registered' in sqlerrm) > 0;
  end;
  if not ok then raise exception 'FAIL unregistered attribute must be rejected'; end if;
end $$;

-- structural guards -----------------------------------------------------------------
do $$
declare
  car uuid := (select id from memory.entities where name = 'Porsche');
  cur uuid := (select id from memory.current_assertions where entity_id = car and attribute = 'parked_at');
  ok boolean := false;
begin
  begin
    update memory.assertions set value = '"moon"' where id = cur;
  exception when others then ok := position('immutable' in sqlerrm) > 0; end;
  if not ok then raise exception 'FAIL value must be immutable'; end if;
  ok := false;
  begin
    delete from memory.assertions where id = cur;
  exception when others then ok := position('never deleted' in sqlerrm) > 0; end;
  if not ok then raise exception 'FAIL assertions must not be deletable'; end if;
  ok := false;
  begin
    insert into memory.assertions (entity_id, attribute, value, valid, asserted_by)
    values (car, 'parked_at', '"street"', tstzrange(now(), null, '[)'), 'test');
  exception when exclusion_violation then ok := true; end;
  if not ok then raise exception 'FAIL overlapping single value must violate the exclusion constraint'; end if;
  ok := false;
  begin
    delete from memory.observations where id = (select min(id) from memory.observations);
  exception when others then ok := position('append-only' in sqlerrm) > 0; end;
  if not ok then raise exception 'FAIL observations must be append-only'; end if;
end $$;

-- deprecate: leaves the current view and stops blocking -----------------------------
do $$
declare
  car uuid := (select id from memory.entities where name = 'Porsche');
  cur uuid := (select id from memory.current_assertions where entity_id = car and attribute = 'parked_at');
  n int;
begin
  perform memory.deprecate_fact(cur, 'test');
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'parked_at';
  if n <> 0 then raise exception 'FAIL deprecated value must leave the current view'; end if;
  perform memory.assert_fact(car, 'parked_at', '"street"', 'test');
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'parked_at';
  if n <> 1 then raise exception 'FAIL a new value should be accepted after deprecation'; end if;
end $$;

-- relationships -----------------------------------------------------------------------
do $$
declare
  me uuid := (select id from memory.entities where name = 'Carter');
  acme uuid := (select id from memory.entities where name = 'Acme Corp');
  sam uuid := (select id from memory.entities where name = 'Sam');
  r1 memory.relationships; r2 memory.relationships;
  n int;
begin
  r1 := memory.assert_relationship(me, 'employed_by', acme, 'test', '{"title": "engineer"}');
  r2 := memory.assert_relationship(me, 'employed_by', acme, 'test', '{"team": "infra"}');
  if r1.id = r2.id then raise exception 'FAIL changed properties need a new revision'; end if;
  if (select properties from memory.relationships where id = r1.id) <> '{"title": "engineer"}'::jsonb then raise exception 'FAIL old properties were overwritten'; end if;
  if r2.properties <> '{"title": "engineer", "team": "infra"}'::jsonb then raise exception 'FAIL properties should merge'; end if;
  perform memory.assert_relationship(me, 'friends_with', sam, 'test');
  perform memory.assert_relationship(me, 'friends_with', acme, 'test');
  select count(*) into n from memory.current_relationships where subject_id = me and relation = 'friends_with';
  if n <> 2 then raise exception 'FAIL multi relation should allow two objects'; end if;
  perform memory.retract_relationship(r2.id, 'test');
  select count(*) into n from memory.current_relationships where subject_id = me and relation = 'employed_by';
  if n <> 0 then raise exception 'FAIL retracted relationship should not be current'; end if;
end $$;

-- merge -------------------------------------------------------------------------------
do $$
declare
  dup memory.entities;
  car uuid := (select id from memory.entities where name = 'Porsche');
  n int;
begin
  dup := memory.upsert_entity('vehicle', 'Porsche 911', 'test');
  perform memory.assert_fact(dup.id, 'hobby', '"track days"', 'test');   -- multi-valued, no conflict on merge
  perform memory.merge_entities(dup.id, car, 'test');
  if (select merged_into from memory.entities where id = dup.id) <> car then raise exception 'FAIL merge pointer'; end if;
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'hobby';
  if n <> 1 then raise exception 'FAIL merged assertions should move to the survivor'; end if;
  select count(*) into n from memory.entity_aliases where entity_id = car and alias_norm = 'porsche 911';
  if n <> 1 then raise exception 'FAIL merged aliases should move to the survivor'; end if;
  select count(*) into n from memory.find_entity('Porsche 911', 'vehicle') f where f.entity_id = car;
  if n <> 1 then raise exception 'FAIL merged name should resolve to the survivor'; end if;
end $$;

-- staleness ---------------------------------------------------------------------------
do $$
declare
  car uuid := (select id from memory.entities where name = 'Porsche');
  n int;
begin
  update memory.assertions set last_confirmed_at = now() - interval '10 days'
   where entity_id = car and attribute = 'parked_at' and upper_inf(valid) and rank <> 'deprecated';
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'parked_at' and stale;
  if n <> 1 then raise exception 'FAIL parked_at should be stale after 10 days'; end if;
  select count(*) into n from memory.current_assertions where entity_id = car and attribute = 'mileage' and stale;
  if n <> 0 then raise exception 'FAIL mileage should not be stale yet'; end if;
end $$;

-- operational tables accept rows --------------------------------------------------------
insert into memory.conversations (agent, device, runtime) values ('morning', 'mac', 'test');
insert into memory.messages (conversation_id, seq, role, content)
  select id, 1, 'assistant', 'Morning.' from memory.conversations limit 1;
insert into memory.plans (day, item, category, status, origin, rationale, created_by)
  values (current_date, 'move the car before street cleaning', 'errand', 'proposed', 'map', 'parked_at is 5th street and cleaning is Tuesday', 'test');
insert into memory.rules (kind, key, text, value, created_by) values ('tuning', 'question_budget', 'question_budget = 2', '2', 'test');
insert into memory.questions (kind, text, ref_table, ref_id, score, created_by)
  values ('stale', 'Still parked in the driveway?', 'assertions', 'x', 3.0, 'test');
insert into memory.connectors (name, status, needs) values ('gmail', 'needs_setup', 'grant Gmail read access');

select 'ALL CHECKS PASSED' as result;
