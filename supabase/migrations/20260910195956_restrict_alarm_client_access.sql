-- Supabase may explicitly grant new public functions to anon/authenticated through
-- default privileges. The authenticated edge handler is the only client gateway.
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'assistant_client%' loop
  execute format('revoke all on function %s from public, anon, authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;
revoke all on function memory.reminder_action(jsonb),memory.reminder_action_without_alarm(jsonb),assistant.alarm_changed() from public,anon,authenticated;
grant execute on function memory.reminder_action(jsonb),memory.reminder_action_without_alarm(jsonb),assistant.alarm_changed() to service_role;
