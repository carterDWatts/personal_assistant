alter table assistant.turns add column notification jsonb;
alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v6;
revoke all on function public.assistant_client_v6(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; previous assistant.turns; wanted jsonb:=p_args->'notification';
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action <> 'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='submit' then
  if wanted is not null and wanted<>'null'::jsonb then
   if wanted->>'kind'='notice' then
    perform 1 from assistant.attention where id=(wanted->>'id')::uuid;
   elsif wanted->>'kind'='reminder' then
    perform 1 from memory.reminders where id=(wanted->>'id')::uuid;
   else raise exception 'invalid_request' using errcode='22023'; end if;
   if not found then raise exception 'invalid_request' using errcode='22023'; end if;
  else wanted:=null; end if;
  select * into previous from assistant.turns where user_id=p_user and client_message_id=(p_args->>'client_message_id')::uuid;
  if found and previous.notification is distinct from wanted then raise exception 'idempotency_conflict'; end if;
 end if;
 result:=public.assistant_client_v6(p_user,p_device,p_action,p_args);
 if p_action='submit' then update assistant.turns set notification=wanted where id=(result->>'turn_id')::uuid; end if;
 return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
