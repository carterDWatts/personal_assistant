alter table memory.reminders add column merged_into uuid references memory.reminders(id),
 add column merge_reason text,
 add constraint reminders_merge_distinct check(merged_into is null or (merged_into<>id and status='cancelled' and merge_reason is not null));

-- One-time check-ins retain their history but do not remain on the task list.
create view memory.active_reminders with(security_invoker=true) as
 select * from memory.reminders m where status='open' and
 (kind='task' or (window_end>now() and not exists(select 1 from assistant.reminder_deliveries d where d.reminder_id=m.id and d.version=m.version and d.sent_at is not null)));
revoke all on memory.active_reminders from public,anon,authenticated;
grant select on memory.active_reminders to service_role;
alter function assistant.day_snapshot() rename to day_snapshot_before_reminder_cleanup;
create function assistant.day_snapshot() returns jsonb language sql stable security invoker set search_path='' as $$
 select assistant.day_snapshot_before_reminder_cleanup() || jsonb_build_object('reminders',coalesce((select jsonb_agg(r order by r.next_notify_at) from
  (select * from memory.active_reminders order by next_notify_at limit 100) r),'[]'::jsonb))
$$;
revoke all on function assistant.day_snapshot(),assistant.day_snapshot_before_reminder_cleanup() from public,anon,authenticated;
grant execute on function assistant.day_snapshot(),assistant.day_snapshot_before_reminder_cleanup() to service_role;
