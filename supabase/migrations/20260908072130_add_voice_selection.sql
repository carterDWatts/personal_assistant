alter table assistant.turns add column voice text;
alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v7;
revoke all on function public.assistant_client_v7(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; previous assistant.turns; wanted text:=nullif(p_args->>'voice','');
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action <> 'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='submit' then
  select * into previous from assistant.turns where user_id=p_user and client_message_id=(p_args->>'client_message_id')::uuid;
  if found then
   if previous.voice is distinct from wanted then raise exception 'idempotency_conflict'; end if;
  elsif wanted is not null then
   if not coalesce((p_args->>'speech')::boolean,false) or not exists (
    select 1 from assistant.host h, jsonb_array_elements(h.capabilities->'voices') v where v->>'id'=wanted
   ) then raise exception 'voice_unavailable' using errcode='22023'; end if;
  end if;
 end if;
 result:=public.assistant_client_v7(p_user,p_device,p_action,p_args);
 if p_action='submit' then update assistant.turns set voice=wanted where id=(result->>'turn_id')::uuid; end if;
 return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
