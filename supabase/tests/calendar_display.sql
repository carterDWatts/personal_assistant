begin;
insert into assistant.source_items(source,id,payload,processed_at)
values('calendar-view','current','{"calendars":[],"fetched_at":"2026-09-08T10:00:00Z"}',now());
do $$ begin
 if assistant.day_snapshot()->'calendar'->>'fetched_at' <> '2026-09-08T10:00:00Z' then
  raise exception 'Day snapshot lost calendar freshness';
 end if;
end $$;
update assistant.source_items set last_error='Calendar unavailable' where source='calendar-view';
do $$ begin
 if assistant.day_snapshot()->'calendar'->>'last_error' is not null then
  raise exception 'Unexpected raw column';
 end if;
 if assistant.day_snapshot()->'calendar'->>'error' <> 'Calendar unavailable' then
  raise exception 'Day snapshot hid a refresh failure';
 end if;
end $$;
rollback;
