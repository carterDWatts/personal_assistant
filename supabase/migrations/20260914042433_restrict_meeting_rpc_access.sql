-- Hosted projects may grant new functions to API roles through default privileges.
-- These entry points are only called by the authenticated gateway's service role.
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from anon,authenticated;
revoke all on function public.assistant_client_before_meetings(uuid,uuid,text,jsonb) from anon,authenticated;
revoke all on function memory.import_part(jsonb) from anon,authenticated;
