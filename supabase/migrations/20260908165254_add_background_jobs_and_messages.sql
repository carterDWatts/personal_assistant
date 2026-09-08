create table assistant.jobs (
 id uuid primary key default gen_random_uuid(),
 message_id bigint not null references memory.messages(id),
 task_key text not null check(length(task_key) between 1 and 100),
 task text not null check(length(task) between 1 and 12000),
 runtime text not null check(runtime in ('codex','claude-agent-sdk')),
 model text,
 kind text not null check(kind in ('research','code')),
 status text not null default 'queued' check(status in ('queued','running','completed','failed','cancelled')),
 result text,
 artifacts jsonb not null default '{}',
 created_at timestamptz not null default now(),
 started_at timestamptz,
 finished_at timestamptz,
 unique(message_id,task_key)
);
create index jobs_pending on assistant.jobs(created_at) where status='queued';
alter table assistant.jobs enable row level security;
revoke all on assistant.jobs from public,anon,authenticated;
grant all on assistant.jobs to service_role;

create table assistant.outbound (
 key text primary key,
 message_id bigint not null unique references memory.messages(id),
 reference jsonb,
 created_at timestamptz not null default now()
);
alter table assistant.outbound enable row level security;
revoke all on assistant.outbound from public,anon,authenticated;
grant all on assistant.outbound to service_role;

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v8;
revoke all on function public.assistant_client_v8(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; history jsonb; wanted jsonb;
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action<>'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='notification_message' then
  wanted:=jsonb_build_object('kind',p_args->>'kind','id',p_args->>'id');
  select to_jsonb(m) into result from assistant.outbound o join memory.messages m on m.id=o.message_id
   where o.reference=wanted and (p_args->>'message_id' is null or m.id=(p_args->>'message_id')::bigint) order by o.created_at desc limit 1;
  return jsonb_build_object('message',result);
 end if;
 if p_action='submit' and p_args->'notification'->>'message_id' is not null then
  perform 1 from assistant.outbound where message_id=(p_args->'notification'->>'message_id')::bigint
   and reference=jsonb_build_object('kind',p_args->'notification'->>'kind','id',p_args->'notification'->>'id');
  if not found then raise exception 'invalid_request' using errcode='22023'; end if;
 end if;
 result:=public.assistant_client_v8(p_user,p_device,p_action,p_args);
 if p_action='bootstrap' then
  select coalesce(jsonb_agg(to_jsonb(h) order by h.id),'[]'::jsonb) into history from
   (select id,role,content,created_at,payload from memory.messages where role in ('user','assistant') and content is not null
    and id>coalesce((select max(id) from memory.messages where role='system' and payload->>'event'='chat_cleared'),0)
    order by id desc limit 100) h;
  result:=result||jsonb_build_object('history',history);
 end if;
 return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
