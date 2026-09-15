-- Supabase's default privileges can grant these roles execution directly.
-- The gateway authenticates requests before invoking them as service_role.
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from anon,authenticated;
revoke all on function public.assistant_client_before_replies(uuid,uuid,text,jsonb) from anon,authenticated;
revoke all on function assistant.queue_reply() from anon,authenticated;
