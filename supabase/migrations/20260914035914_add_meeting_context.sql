-- A bounded source excerpt accompanies a turn without becoming a visible user message.
alter table assistant.turns add column meeting_context text check(length(meeting_context)<=12000);
alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_before_meetings;
revoke all on function public.assistant_client_before_meetings(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; wanted text; previous assistant.turns;
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action<>'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='submit' then
  if p_args ? 'meeting_context' and p_args->'meeting_context'<>'null'::jsonb then
   if jsonb_typeof(p_args->'meeting_context')<>'string' or length(p_args->>'meeting_context')>12000 then
    raise exception 'invalid_request' using errcode='22023';
   end if;
   wanted:=p_args->>'meeting_context';
  end if;
  select * into previous from assistant.turns where user_id=p_user and client_message_id=(p_args->>'client_message_id')::uuid;
  if found and previous.meeting_context is distinct from wanted then raise exception 'idempotency_conflict'; end if;
 end if;
 result:=public.assistant_client_before_meetings(p_user,p_device,p_action,p_args);
 if p_action='submit' then update assistant.turns set meeting_context=wanted where id=(result->>'turn_id')::uuid; end if;
 return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;

-- Reuse the import queue, but classify meeting speech as external evidence at write time.
alter table memory.imports add column source text check(source='meeting');
create or replace function memory.import_part(p_args jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare i memory.imports; wanted uuid := (p_args->>'id')::uuid; n integer := (p_args->>'part')::integer;
 body text := p_args->>'text'; existing text; segment uuid; m bigint; piece record;
begin
 if p_args->>'source' is not null and p_args->>'source'<>'meeting' then raise exception 'invalid_request' using errcode='22023'; end if;
 insert into memory.imports(id,title,kind,runtime,parts,source) values(wanted,p_args->>'title',p_args->>'kind',p_args->>'runtime',(p_args->>'parts')::integer,p_args->>'source') on conflict do nothing;
 select * into strict i from memory.imports where id=wanted for update;
 if i.source is distinct from p_args->>'source' or i.title is distinct from p_args->>'title' or i.kind is distinct from p_args->>'kind' or i.runtime is distinct from p_args->>'runtime' or i.parts is distinct from (p_args->>'parts')::integer then raise exception 'idempotency_conflict'; end if;
 if n is null or n < 0 or n >= i.parts then raise exception 'invalid_request' using errcode='22023'; end if;
 select content into existing from memory.import_parts where import_id=wanted and part=n;
 if found and existing is distinct from body then raise exception 'idempotency_conflict'; end if;
 insert into memory.import_parts(import_id,part,content) values(wanted,n,body) on conflict do nothing;
 if i.queued_at is null and (select count(*) from memory.import_parts where import_id=wanted)=i.parts then
   insert into memory.conversations(agent,device,runtime,runtime_policy_version) values('context-import','import',i.runtime,4) returning id into segment;
   for piece in select * from memory.import_parts where import_id=wanted order by part loop
     insert into memory.messages(conversation_id,seq,role,content,payload) values(segment,piece.part+1,'system',piece.content,jsonb_build_object('import_id',wanted,'kind',i.kind,'title',i.title,'part',piece.part,'parts',i.parts) || case when i.source='meeting' then jsonb_build_object('external',true,'source','meeting') else '{}'::jsonb end) returning id into m;
     update memory.import_parts set message_id=m where import_id=wanted and part=piece.part;
     insert into memory.memory_jobs(message_id) values(m);
   end loop;
   update memory.imports set queued_at=now(),conversation_id=segment where id=wanted;
 end if;
 return jsonb_build_object('saved',true,'imports',memory.import_status());
end $$;
revoke all on function memory.import_part(jsonb) from public;
grant execute on function memory.import_part(jsonb) to service_role;
