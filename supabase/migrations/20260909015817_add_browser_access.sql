create table assistant.browser_host (
 singleton boolean primary key default true check(singleton),
 public_key text not null,
 seen_at timestamptz not null default now()
);
create table assistant.browser_sessions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 origin text not null,
 url text not null,
 state text not null default 'requested' check(state in ('requested','human','ready','closed')),
 storage text,
 allowed_origins text[] not null default array[]::text[],
 requested_for text not null,
 updated_at timestamptz not null default now(),
 unique(user_id,origin)
);
create table assistant.browser_commands (
 id uuid primary key,
 session_id uuid not null references assistant.browser_sessions(id) on delete cascade,
 actor text not null check(actor in ('human','agent')),
 encrypted text not null,
 status text not null default 'pending' check(status in ('pending','running','done','failed')),
 result jsonb,
 created_at timestamptz not null default now()
);
create index browser_pending on assistant.browser_commands(created_at) where status='pending';
alter table assistant.browser_host enable row level security;
alter table assistant.browser_sessions enable row level security;
alter table assistant.browser_commands enable row level security;
grant select,insert,update,delete on assistant.browser_host,assistant.browser_sessions,assistant.browser_commands to service_role;

create function public.assistant_browser(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare s assistant.browser_sessions; r jsonb;
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 perform assistant.require_device(p_user,p_device);
 if p_action='browser_list' then
  return jsonb_build_object('sessions',coalesce((select jsonb_agg(jsonb_build_object('id',id,'origin',origin,'state',state)) from assistant.browser_sessions where user_id=p_user and state<>'closed'),'[]'::jsonb));
 end if;
 select * into s from assistant.browser_sessions where id=(p_args->>'session_id')::uuid and user_id=p_user for update;
 if not found then raise exception 'invalid_request' using errcode='22023'; end if;
 if p_action in ('browser_begin','browser_disconnect') and exists(select 1 from assistant.browser_commands where session_id=s.id and status='running') then
  raise exception 'browser_busy';
 end if;
 if p_action='browser_begin' then
  if not exists(select 1 from assistant.browser_host where seen_at>now()-interval '60 seconds') then raise exception 'browser_unavailable'; end if;
  update assistant.browser_sessions set state='human',updated_at=now() where id=s.id;
  return jsonb_build_object('public_key',(select public_key from assistant.browser_host),'origin',s.origin,'session_id',s.id);
 elsif p_action='browser_command' then
  if s.state<>'human' or s.updated_at<now()-interval '15 minutes' then raise exception 'invalid_request'; end if;
  if length(p_args->>'encrypted') not between 1 and 24000 then raise exception 'invalid_request'; end if;
  insert into assistant.browser_commands(id,session_id,actor,encrypted) values((p_args->>'id')::uuid,s.id,'human',p_args->>'encrypted') on conflict(id) do nothing;
  update assistant.browser_sessions set updated_at=now() where id=s.id;
  return jsonb_build_object('id',p_args->>'id');
 elsif p_action='browser_result' then
  select jsonb_build_object('status',status,'result',result) into r from assistant.browser_commands where id=(p_args->>'id')::uuid and session_id=s.id and actor='human';
  return coalesce(r,'{}'::jsonb);
 elsif p_action='browser_disconnect' then
  update assistant.browser_sessions set state='closed',storage=null,updated_at=now() where id=s.id;
  delete from assistant.browser_commands where session_id=s.id;
  return '{"disconnected":true}'::jsonb;
 end if;
 raise exception 'invalid_request' using errcode='22023';
end $$;
revoke all on function public.assistant_browser(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_browser(uuid,uuid,text,jsonb) to service_role;
