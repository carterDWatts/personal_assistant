create table memory.imports (
 id uuid primary key,
 title text not null check (length(title) between 1 and 200),
 kind text not null check (kind in ('current','history')),
 runtime text not null check (runtime in ('codex','claude-agent-sdk')),
 parts integer not null check (parts between 1 and 200),
 created_at timestamptz not null default now(),
 queued_at timestamptz,
 conversation_id uuid references memory.conversations(id)
);
create table memory.import_parts (
 import_id uuid not null references memory.imports(id),
 part integer not null check (part between 0 and 199),
 content text not null check (length(content) between 1 and 12000),
 message_id bigint unique references memory.messages(id),
 primary key (import_id,part)
);
alter table memory.imports enable row level security;
alter table memory.import_parts enable row level security;
grant select,insert,update on memory.imports,memory.import_parts to service_role;

create function memory.import_status() returns jsonb language sql security invoker set search_path='' as $$
 select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) from (
 select i.id,i.title,i.kind,i.created_at,i.parts,i.queued_at,
 (select count(*) from memory.import_parts p where p.import_id=i.id) as uploaded,
 (select count(*) from memory.import_parts p join memory.memory_jobs j on j.message_id=p.message_id where p.import_id=i.id and j.status='done') as processed,
 (select count(*) from memory.import_parts p join memory.memory_jobs j on j.message_id=p.message_id where p.import_id=i.id and j.status='error') as errors
 from memory.imports i order by i.created_at desc limit 30) x
$$;
create function memory.import_part(p_args jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare i memory.imports; wanted uuid := (p_args->>'id')::uuid; n integer := (p_args->>'part')::integer;
 body text := p_args->>'text'; existing text; segment uuid; m bigint; piece record;
begin
 insert into memory.imports(id,title,kind,runtime,parts) values(wanted,p_args->>'title',p_args->>'kind',p_args->>'runtime',(p_args->>'parts')::integer) on conflict do nothing;
 select * into strict i from memory.imports where id=wanted for update;
 if i.title is distinct from p_args->>'title' or i.kind is distinct from p_args->>'kind' or i.runtime is distinct from p_args->>'runtime' or i.parts is distinct from (p_args->>'parts')::integer then raise exception 'idempotency_conflict'; end if;
 if n is null or n < 0 or n >= i.parts then raise exception 'invalid_request' using errcode='22023'; end if;
 select content into existing from memory.import_parts where import_id=wanted and part=n;
 if found and existing is distinct from body then raise exception 'idempotency_conflict'; end if;
 insert into memory.import_parts(import_id,part,content) values(wanted,n,body) on conflict do nothing;
 if i.queued_at is null and (select count(*) from memory.import_parts where import_id=wanted)=i.parts then
   insert into memory.conversations(agent,device,runtime,runtime_policy_version) values('context-import','import',i.runtime,4) returning id into segment;
   for piece in select * from memory.import_parts where import_id=wanted order by part loop
     insert into memory.messages(conversation_id,seq,role,content,payload) values(segment,piece.part+1,'system',piece.content,jsonb_build_object('import_id',wanted,'kind',i.kind,'title',i.title,'part',piece.part,'parts',i.parts)) returning id into m;
     update memory.import_parts set message_id=m where import_id=wanted and part=piece.part;
     insert into memory.memory_jobs(message_id) values(m);
   end loop;
   update memory.imports set queued_at=now(),conversation_id=segment where id=wanted;
 end if;
 return jsonb_build_object('saved',true,'imports',memory.import_status());
end $$;
revoke all on function memory.import_part(jsonb),memory.import_status() from public;
grant execute on function memory.import_part(jsonb),memory.import_status() to service_role;

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v4;
revoke all on function public.assistant_client_v4(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action <> 'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='import_part' then return memory.import_part(p_args);
 elsif p_action='imports' then return jsonb_build_object('imports',memory.import_status()); end if;
 return public.assistant_client_v4(p_user,p_device,p_action,p_args);
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
