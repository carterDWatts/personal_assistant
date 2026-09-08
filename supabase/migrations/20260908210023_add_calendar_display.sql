alter function assistant.day_snapshot() rename to day_snapshot_v3;
create function assistant.day_snapshot() returns jsonb language sql stable security invoker set search_path='' as $$
 select assistant.day_snapshot_v3() || jsonb_build_object('calendar',coalesce(
 (select payload || jsonb_build_object('error',last_error) from assistant.source_items where source='calendar-view' and id='current'), '{}'::jsonb))
$$;
revoke all on function assistant.day_snapshot() from public;
grant execute on function assistant.day_snapshot() to service_role;
