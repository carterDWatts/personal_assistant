-- New evidence wakes related plans; a nightly sweep covers missed semantic links.
create or replace function memory.queue_plan_reviews() returns trigger language plpgsql security invoker set search_path='' as $$
declare material text; terms text[]; changed_id bigint; related_entities uuid[];
begin
 if current_setting('assistant.reconciling_plans',true)='on' then return new; end if;
 if tg_table_name='plans' then
  material:=new.item||' '||coalesce(new.outcome_note,''); changed_id:=new.id; related_entities:=array[new.entity_id];
 else
  select m.content||' '||coalesce((select a.content from memory.messages a where a.conversation_id=m.conversation_id and a.id<m.id and a.role='assistant' order by a.id desc limit 1),'')
   into material from memory.messages m where m.id=new.message_id;
  select array_agg(distinct entity_id) into related_entities from (
   select a.entity_id from memory.assertions a join memory.assertion_sources s on s.assertion_id=a.id
    join memory.observations o on o.id=s.observation_id where o.message_id=new.message_id
   union select unnest(array[r.subject_id,r.object_id]) from memory.relationships r
    join memory.relationship_sources s on s.relationship_id=r.id
    join memory.observations o on o.id=s.observation_id where o.message_id=new.message_id
  ) changed;
 end if;
 select array_agg(distinct id) into related_entities from (
  select unnest(related_entities) id union select unnest(array[r.subject_id,r.object_id])
   from memory.current_relationships r where r.subject_id=any(related_entities) or r.object_id=any(related_entities)
 ) connected;
 select coalesce(material,'')||' '||coalesce(string_agg(name,' '),'') into material
  from memory.entities where id=any(related_entities);
 terms:=tsvector_to_array(to_tsvector('english',coalesce(material,'')));
 insert into memory.plan_reviews(plan_id,available_at)
  select id,now()+interval '30 seconds' from memory.plans where superseded_by is null and status in ('planned','partial','proposed')
   and (id=changed_id or entity_id=any(related_entities) or tsvector_to_array(to_tsvector('english',item)) && terms)
  on conflict(plan_id) do update set requested_at=clock_timestamp(),
   available_at=case when memory.plan_reviews.completed_at>=memory.plan_reviews.requested_at then now()+interval '30 seconds' else memory.plan_reviews.available_at end;
 return new;
end $$;

create function memory.close_resolved_reminder_questions() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.status in ('done','cancelled') then
  update memory.questions set closed_at=now(),closed_reason='Reminder '||new.status
   where ref_table='reminders' and ref_id=new.id::text and closed_at is null;
 end if;
 return new;
end $$;
revoke all on function memory.close_resolved_reminder_questions() from public;
create trigger resolved_reminder_questions after update of status on memory.reminders
 for each row when(old.status is distinct from new.status) execute function memory.close_resolved_reminder_questions();
update memory.questions q set closed_at=now(),closed_reason='Linked reminder already resolved'
 from memory.reminders r where q.ref_table='reminders' and q.ref_id=r.id::text and q.closed_at is null and r.status in ('done','cancelled');
update memory.questions q set ref_id=p.superseded_by::text
 from memory.plans p where q.ref_table='plans' and q.ref_id=p.id::text and p.superseded_by is not null and q.closed_at is null;
update memory.questions q set closed_at=now(),closed_reason='Linked plan already resolved',answer=p.outcome_note
 from memory.plans p where q.ref_table='plans' and q.ref_id=p.id::text and p.status in ('done','skipped','dropped') and q.closed_at is null;
