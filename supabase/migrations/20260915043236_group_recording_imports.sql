-- Batches remain individually retryable while retaining their source recording.
alter table memory.imports add column recording_id uuid;
alter table memory.imports add column recording_index integer;
alter table memory.imports add constraint recording_batch_valid check (
 (recording_id is null and recording_index is null) or
 (recording_id is not null and recording_index is not null and recording_index>=0 and source is not distinct from 'meeting' and parts=1)
);
create unique index imports_recording_batch on memory.imports(recording_id,recording_index) where recording_id is not null;

create or replace function memory.import_part(p_args jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare i memory.imports; wanted uuid := (p_args->>'id')::uuid; n integer := (p_args->>'part')::integer;
 body text := p_args->>'text'; existing text; segment uuid; m bigint; piece record;
begin
 if p_args->>'source' is not null and p_args->>'source'<>'meeting' then raise exception 'invalid_request' using errcode='22023'; end if;
 if p_args->>'recording_id' is not null then
  perform pg_advisory_xact_lock(hashtextextended('recording:' || (p_args->>'recording_id')::uuid::text,0));
  if exists(select 1 from memory.imports prior where prior.recording_id=(p_args->>'recording_id')::uuid
    and (prior.kind is distinct from p_args->>'kind' or prior.runtime is distinct from p_args->>'runtime')) then
   raise exception 'recording_context_conflict';
  end if;
 end if;
 insert into memory.imports(id,title,kind,runtime,parts,source,recording_id,recording_index) values(wanted,p_args->>'title',p_args->>'kind',p_args->>'runtime',(p_args->>'parts')::integer,p_args->>'source',(p_args->>'recording_id')::uuid,(p_args->>'recording_index')::integer) on conflict do nothing;
 select * into strict i from memory.imports where id=wanted for update;
 if i.source is distinct from p_args->>'source' or i.title is distinct from p_args->>'title' or i.kind is distinct from p_args->>'kind' or i.runtime is distinct from p_args->>'runtime' or i.parts is distinct from (p_args->>'parts')::integer then raise exception 'idempotency_conflict'; end if;
 -- An old client's acknowledged-lost upload may acquire grouping metadata on retry.
 if p_args->>'recording_id' is not null then
  if i.recording_id is null then
   update memory.imports set recording_id=(p_args->>'recording_id')::uuid,
    recording_index=(p_args->>'recording_index')::integer where id=wanted returning * into i;
  elsif i.recording_id is distinct from (p_args->>'recording_id')::uuid
     or i.recording_index is distinct from (p_args->>'recording_index')::integer then
   raise exception 'idempotency_conflict';
  end if;
 elsif p_args->>'recording_index' is not null then
  raise exception 'invalid_request' using errcode='22023';
 end if;
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

revoke all on function memory.import_part(jsonb) from anon,authenticated;
