-- Unopened outbound messages belong to the inbox, not the conversation.
alter table assistant.outbound add column opened_at timestamptz;
create table assistant.inbox_opens (
 request_id uuid primary key,
 source_message_id bigint not null references assistant.outbound(message_id),
 message_id bigint not null references memory.messages(id)
);
alter table assistant.inbox_opens enable row level security;
revoke all on assistant.inbox_opens from public,anon,authenticated;
grant select,insert on assistant.inbox_opens to service_role;

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v10;
revoke all on function public.assistant_client_v10(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; history jsonb; source memory.messages; selected memory.messages; segment uuid; request uuid; source_id bigint; selected_id bigint;
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action<>'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='inbox' then
  select coalesce(jsonb_agg(to_jsonb(h) order by h.id desc),'[]'::jsonb) into result from
   (select m.id,m.role,m.content,m.payload,m.created_at,o.opened_at from assistant.outbound o join memory.messages m on m.id=o.message_id
    where p_args->>'before_id' is null or m.id<(p_args->>'before_id')::bigint order by m.id desc limit 100) h;
  return jsonb_build_object('messages',result);
 end if;
 if p_action='inbox_open' then
  request:=(p_args->>'request_id')::uuid;
  if request is null then raise exception 'invalid_request' using errcode='22023'; end if;
  select m.* into source from assistant.outbound o join memory.messages m on m.id=o.message_id where m.id=(p_args->>'message_id')::bigint;
  if not found then raise exception 'invalid_request' using errcode='22023'; end if;
  select o.source_message_id,o.message_id into source_id,selected_id from assistant.inbox_opens o where o.request_id=request;
  if found then
   if source_id<>source.id then raise exception 'idempotency_conflict'; end if;
   select * into selected from memory.messages where id=selected_id;
   return jsonb_build_object('message',to_jsonb(selected));
  end if;
  if exists(select 1 from assistant.turns where status in ('queued','running')) then raise exception 'conversation_busy'; end if;
  select * into selected from memory.messages where id>coalesce((select max(id) from memory.messages where payload->>'event'='chat_cleared'),0) and role in ('user','assistant') and not coalesce((payload->>'proactive')::boolean,false) order by id desc limit 1;
  if selected.payload->>'inbox_source_id' is distinct from source.id::text then
   select id into segment from memory.conversations where agent='inbox' order by started_at desc limit 1;
   if segment is null then insert into memory.conversations(agent,device,runtime) values('inbox','cloud','background') returning id into segment; end if;
   insert into memory.messages(conversation_id,seq,role,content,payload) values(segment,
    (select coalesce(max(seq),0)+1 from memory.messages where conversation_id=segment),'assistant',source.content,
    jsonb_build_object('inbox_source_id',source.id::text,'reference',source.payload->'reference')) returning * into selected;
  end if;
  insert into assistant.inbox_opens values(request,source.id,selected.id);
  update assistant.outbound set opened_at=coalesce(opened_at,clock_timestamp()) where message_id=source.id;
  perform assistant.emit(p_user,null,jsonb_build_object('type','inbox_opened','message',to_jsonb(selected)));
  return jsonb_build_object('message',to_jsonb(selected));
 end if;
 result:=public.assistant_client_v10(p_user,p_device,p_action,p_args);
 if p_action='bootstrap' then
  select coalesce(jsonb_agg(to_jsonb(h) order by h.id),'[]'::jsonb) into history from
   (select id,role,content,created_at,payload from memory.messages where role in ('user','assistant') and content is not null
    and not coalesce((payload->>'proactive')::boolean,false)
    and id>coalesce((select max(id) from memory.messages where role='system' and payload->>'event'='chat_cleared'),0)
    order by id desc limit 100) h;
  return result||jsonb_build_object('history',history);
 end if;
 return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
