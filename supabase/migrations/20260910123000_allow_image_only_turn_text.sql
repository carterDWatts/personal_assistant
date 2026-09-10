alter table assistant.turns drop constraint turns_text_check;
alter table assistant.turns add constraint turns_text_check check(length(text) between 0 and 32000);

create or replace function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare
 result jsonb; previous assistant.turns; wanted_images uuid[]; submitted_text text; wanted_model text; wanted_mode text; wants_speech boolean; wanted_voice text; wanted_notification jsonb; caps jsonb; t assistant.turns;
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action<>'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action<>'submit' then
  result:=public.assistant_client_v10(p_user,p_device,p_action,p_args);
  if p_action='bootstrap' then
   declare history jsonb; inbox jsonb;
   begin
    select coalesce(jsonb_agg(to_jsonb(h) order by h.id),'[]'::jsonb) into history from
     (select id,role,content,created_at,payload from memory.messages where role in ('user','assistant') and content is not null
      and not coalesce((payload->>'proactive')::boolean,false) and not exists(select 1 from assistant.inbox_cancellations ic where ic.message_id=memory.messages.id)
      and id>coalesce((select max(id) from memory.messages where role='system' and payload->>'event'='chat_cleared'),0)
      order by id desc limit 100) h;
    select coalesce(jsonb_agg(to_jsonb(h) order by h.id desc),'[]'::jsonb) into inbox from
     (select m.id,m.role,m.content,m.payload,m.created_at,o.opened_at from assistant.outbound o join memory.messages m on m.id=o.message_id order by m.id desc limit 100) h;
    return result||jsonb_build_object('history',history,'inbox',inbox);
   end;
  end if;
  return result;
 end if;
 if jsonb_typeof(p_args->'text') is distinct from 'string' then raise exception 'invalid_request' using errcode='22023'; end if;
 submitted_text:=p_args->>'text';
 wanted_images:=array(select jsonb_array_elements_text(coalesce(p_args->'images','[]'::jsonb))::uuid);
 if length(submitted_text)>32000 or (length(submitted_text)=0 and cardinality(wanted_images)=0) then raise exception 'invalid_request' using errcode='22023'; end if;
 if cardinality(wanted_images)>4 or cardinality(wanted_images)<>(select count(distinct i) from unnest(wanted_images) i) or exists(
   select 1 from unnest(wanted_images) i where not exists(select 1 from assistant.images where id=i and user_id=p_user and ready)
 ) then raise exception 'invalid_request' using errcode='22023'; end if;
 wanted_model:=nullif(p_args->>'model',''); wanted_mode:=coalesce(p_args->>'mode','talk'); wants_speech:=coalesce((p_args->>'speech')::boolean,false); wanted_voice:=nullif(p_args->>'voice',''); wanted_notification:=p_args->'notification';
 if wanted_mode not in ('talk','morning') then raise exception 'invalid_request' using errcode='22023'; end if;
 if p_args ? 'speech' and jsonb_typeof(p_args->'speech') <> 'boolean' then raise exception 'invalid_request' using errcode='22023'; end if;
 if wanted_notification is not null and wanted_notification<>'null'::jsonb then
  if wanted_notification->>'kind'='notice' then perform 1 from assistant.attention where id=(wanted_notification->>'id')::uuid;
  elsif wanted_notification->>'kind'='reminder' then perform 1 from memory.reminders where id=(wanted_notification->>'id')::uuid;
  else raise exception 'invalid_request' using errcode='22023'; end if;
  if not found then raise exception 'invalid_request' using errcode='22023'; end if;
 else wanted_notification:=null; end if;
 select * into previous from assistant.turns where user_id=p_user and client_message_id=(p_args->>'client_message_id')::uuid;
 if found then
  if previous.text<>submitted_text or previous.images is distinct from wanted_images or previous.model is distinct from wanted_model or previous.mode<>wanted_mode or previous.speech<>wants_speech or previous.voice is distinct from wanted_voice or previous.notification is distinct from wanted_notification then raise exception 'idempotency_conflict'; end if;
  return jsonb_build_object('turn_id',previous.id,'status',previous.status);
 end if;
 select capabilities into caps from assistant.host; caps:=coalesce(caps,'{}');
 if wanted_model is not null and not exists(select 1 from jsonb_array_elements(coalesce(caps->'models','[]')) m where m->>'id'=wanted_model) then raise exception 'model_unavailable' using errcode='22023'; end if;
 if wants_speech and coalesce((caps->>'speech')::boolean,false)=false then raise exception 'speech_unavailable' using errcode='22023'; end if;
 if wanted_voice is not null and (not wants_speech or not exists(select 1 from jsonb_array_elements(coalesce(caps->'voices','[]')) v where v->>'id'=wanted_voice)) then raise exception 'voice_unavailable' using errcode='22023'; end if;
 if exists(select 1 from assistant.turns where user_id=p_user and status in ('queued','running')) then raise exception 'conversation_busy'; end if;
 insert into assistant.turns(user_id,device_id,client_message_id,text,model,speech,mode,voice,notification,images)
  values(p_user,p_device,(p_args->>'client_message_id')::uuid,submitted_text,wanted_model,wants_speech,wanted_mode,wanted_voice,wanted_notification,wanted_images) returning * into t;
 perform pg_notify('assistant_commands',t.id::text);
 return jsonb_build_object('turn_id',t.id,'status',t.status);
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
