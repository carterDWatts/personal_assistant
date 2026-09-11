alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_before_work_updates;
revoke all on function public.assistant_client_before_work_updates(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare source record; selected memory.messages; segment uuid; messages jsonb := '[]';
begin
 if p_action<>'work_updates' then return public.assistant_client_before_work_updates(p_user,p_device,p_action,p_args); end if;
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 perform assistant.require_device(p_user,p_device);
 -- Keep a streamed reply intact. The next foreground poll receives the update.
 if exists(select 1 from assistant.turns where status in ('queued','running')) then return jsonb_build_object('messages',messages); end if;
 for source in
  select distinct on(j.id) j.id job_id,m.* from assistant.outbound o join memory.messages m on m.id=o.message_id
   join assistant.attention a on o.key='notice:'||a.id::text and a.source='job'
   join assistant.jobs j on j.id::text=split_part(a.source_id,':',1)
   join memory.messages request on request.id=j.message_id and request.role='user'
  where o.opened_at is null and m.created_at>now()-interval '90 seconds'
   and j.task_key not like 'proactive:%' and j.task_key not like 'development:%'
  order by j.id,m.id desc limit 10
 loop
  select id into segment from memory.conversations where agent='inbox' order by started_at desc limit 1;
  if segment is null then insert into memory.conversations(agent,device,runtime) values('inbox','cloud','background') returning id into segment; end if;
  insert into memory.messages(conversation_id,seq,role,content,payload)
   values(segment,(select coalesce(max(seq),0)+1 from memory.messages where conversation_id=segment),'assistant',source.content,
    jsonb_build_object('work_update',source.id::text,'job_id',source.job_id::text,'reference',source.payload->'reference')) returning * into selected;
  update assistant.outbound o set opened_at=clock_timestamp() from assistant.attention a
   where o.key='notice:'||a.id::text and a.source='job' and split_part(a.source_id,':',1)=source.job_id::text and o.message_id<=source.id and o.opened_at is null;
  perform assistant.emit(p_user,null,jsonb_build_object('type','work_update','message',to_jsonb(selected)));
  messages:=messages||jsonb_build_array(to_jsonb(selected));
 end loop;
 return jsonb_build_object('messages',messages);
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
