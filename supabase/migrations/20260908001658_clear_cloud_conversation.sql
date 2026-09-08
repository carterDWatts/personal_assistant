-- Clearing hides prior chat without deleting messages, extraction jobs or structured memory.
create or replace function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; marker bigint; segment uuid; request_id uuid;
begin
  if p_action='clear' then
    perform 1 from assistant.owner where user_id=p_user for update;
    if not found then raise exception 'account_denied' using errcode='42501'; end if;
    perform assistant.require_device(p_user,p_device);
    request_id := (p_args->>'request_id')::uuid;
    if request_id is not null then
      select id into marker from memory.messages
        where role='system' and payload->>'event'='chat_cleared'
          and payload->>'clear_request_id'=request_id::text
          and payload->>'clear_device_id'=p_device::text order by id desc limit 1;
      if found then return jsonb_build_object('status','cleared','cutoff',marker); end if;
    end if;
    -- Do not cut off a running external action or silently discard a queued message.
    if exists(select 1 from assistant.turns where user_id=p_user and status in ('queued','running')) then
      raise exception 'conversation_busy';
    end if;
    select id into marker from memory.messages where id=(select max(id) from memory.messages)
      and role='system' and payload->>'event'='chat_cleared';
    if marker is null or request_id is not null then
      insert into memory.conversations(agent,device,runtime,runtime_policy_version)
        values('talk','cloud-clear','relay',3) returning id into segment;
      insert into memory.messages(conversation_id,seq,role,payload)
        values(segment,1,'system',jsonb_build_object('event','chat_cleared',
          'clear_request_id',request_id,'clear_device_id',p_device)) returning id into marker;
      perform assistant.emit(p_user,null,jsonb_build_object('type','history','messages','[]'::jsonb,'cutoff',marker));
    end if;
    return jsonb_build_object('status','cleared','cutoff',marker);
  end if;
  result := assistant.client_base(p_user,p_device,p_action,p_args);
  if p_action='bootstrap' then
    result := result || jsonb_build_object('day',assistant.day_snapshot());
  end if;
  return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
