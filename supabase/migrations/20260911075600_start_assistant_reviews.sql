alter table assistant.turns add column invocation text check(invocation in ('morning','review'));
alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_before_reviews;
revoke all on function public.assistant_client_before_reviews(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare kind text; result jsonb; existing text;
begin
 if p_action<>'start_routine' then return public.assistant_client_before_reviews(p_user,p_device,p_action,p_args); end if;
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 perform assistant.require_device(p_user,p_device);
 kind:=p_args->>'kind';
 if kind is null or kind not in ('morning','review') then raise exception 'invalid_request' using errcode='22023'; end if;
 select invocation into existing from assistant.turns where user_id=p_user and client_message_id=(p_args->>'client_message_id')::uuid;
 if found and existing is distinct from kind then raise exception 'idempotency_conflict'; end if;
 result:=public.assistant_client_before_reviews(p_user,p_device,'submit',p_args || jsonb_build_object(
  'text',case when kind='morning' then 'Open the morning conversation.' else 'Open a review of unfinished commitments and outcomes.' end,
  'mode',case when kind='morning' then 'morning' else 'talk' end));
 update assistant.turns set invocation=kind where id=(result->>'turn_id')::uuid;
 return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
