-- One owner per deployment until the knowledge map itself supports multiple users.
create schema if not exists assistant;
revoke all on schema assistant from public;
grant usage on schema assistant to service_role;
create table assistant.owner (
  singleton boolean primary key default true check (singleton),
  user_id uuid not null unique,
  conversation_id uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);
create table assistant.devices (
  id uuid primary key,
  user_id uuid not null references assistant.owner(user_id),
  name text not null check (length(name) between 1 and 100),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique(user_id,id)
);
create table assistant.turns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references assistant.owner(user_id),
  device_id uuid not null,
  client_message_id uuid not null,
  text text not null check(length(text) between 1 and 32000),
  status text not null default 'queued' check(status in ('queued','running','completed','cancelled','failed')),
  cancel_requested boolean not null default false,
  worker_id uuid,
  lease_until timestamptz,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  unique(user_id,client_message_id),
  unique(user_id,id),
  foreign key(user_id,device_id) references assistant.devices(user_id,id)
);
create unique index one_active_turn on assistant.turns(user_id) where status in ('queued','running');
create table assistant.events (
  cursor bigint generated always as identity primary key,
  turn_id uuid,
  user_id uuid not null references assistant.owner(user_id),
  payload jsonb not null check(jsonb_typeof(payload)='object'),
  created_at timestamptz not null default now(),
  foreign key(user_id,turn_id) references assistant.turns(user_id,id)
);
create index turns_device on assistant.turns(user_id,device_id);
create index events_turn on assistant.events(user_id,turn_id);
create index events_owner_cursor on assistant.events(user_id,cursor);
create table assistant.host (
  singleton boolean primary key default true check(singleton),
  worker_id uuid not null,
  seen_at timestamptz not null default now(),
  lease_until timestamptz not null
);

-- All client operations pass through the authenticated gateway. No direct table API.
alter table assistant.owner enable row level security;
alter table assistant.devices enable row level security;
alter table assistant.turns enable row level security;
alter table assistant.events enable row level security;
alter table assistant.host enable row level security;
grant select,insert,update,delete on all tables in schema assistant to service_role;
grant usage,select on all sequences in schema assistant to service_role;

create function assistant.require_device(p_user uuid,p_device uuid) returns void
language plpgsql security invoker set search_path='' as $$
begin
  if not exists(select 1 from assistant.devices where id=p_device and user_id=p_user and revoked_at is null) then
    raise exception 'device_denied' using errcode='42501';
  end if;
end $$;

-- The owner lock serializes both writes and replay cursors; sequence allocation alone
-- would allow a later cursor to commit before an earlier transaction.
create function assistant.emit(p_user uuid,p_turn uuid,p_payload jsonb) returns bigint
language plpgsql security invoker set search_path='' as $$
declare result bigint;
begin
  perform 1 from assistant.owner where user_id=p_user for update;
  if not found then raise exception 'owner_denied'; end if;
  insert into assistant.events(user_id,turn_id,payload) values(p_user,p_turn,p_payload) returning cursor into result;
  perform pg_notify('assistant_events',result::text);
  return result;
end $$;

create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare t assistant.turns; result jsonb; current_cursor bigint;
begin
  perform 1 from assistant.owner where user_id=p_user for update;
  if not found then raise exception 'account_denied' using errcode='42501'; end if;
  if p_action='register' then
    insert into assistant.devices(id,user_id,name) values(p_device,p_user,p_args->>'name')
      on conflict(id) do nothing;
    perform assistant.require_device(p_user,p_device);
    return jsonb_build_object('device_id',p_device);
  end if;
  perform assistant.require_device(p_user,p_device);
  if p_action='submit' then
    if jsonb_typeof(p_args->'text') is distinct from 'string' or length(p_args->>'text') not between 1 and 32000 then
      raise exception 'invalid_request' using errcode='22023';
    end if;
    select * into t from assistant.turns where user_id=p_user and client_message_id=(p_args->>'client_message_id')::uuid;
    if found then
      if t.text <> p_args->>'text' then raise exception 'idempotency_conflict'; end if;
      return jsonb_build_object('turn_id',t.id,'status',t.status);
    end if;
    if exists(select 1 from assistant.turns where user_id=p_user and status in ('queued','running')) then
      raise exception 'conversation_busy';
    end if;
    insert into assistant.turns(user_id,device_id,client_message_id,text)
      values(p_user,p_device,(p_args->>'client_message_id')::uuid,p_args->>'text') returning * into t;
    perform pg_notify('assistant_commands',t.id::text);
    return jsonb_build_object('turn_id',t.id,'status',t.status);
  elsif p_action='cancel' then
    select * into t from assistant.turns where id=(p_args->>'turn_id')::uuid and user_id=p_user for update;
    if not found then raise exception 'turn_not_found'; end if;
    if t.status='queued' then
      update assistant.turns set status='cancelled',cancel_requested=true,finished_at=now() where id=t.id;
      perform assistant.emit(p_user,t.id,'{"type":"end","status":"cancelled"}');
      return '{"status":"cancelled"}';
    elsif t.status='running' then
      update assistant.turns set cancel_requested=true where id=t.id;
      perform pg_notify('assistant_commands',t.id::text);
      return '{"status":"cancellation_requested"}';
    end if;
    return jsonb_build_object('status',t.status);
  elsif p_action='events' then
    select coalesce(jsonb_agg(jsonb_build_object('version',1,'event_id',e.cursor::text,'cursor',e.cursor,
      'conversation_id',(select conversation_id from assistant.owner where user_id=p_user),'turn_id',e.turn_id,'payload',e.payload,'created_at',e.created_at) order by e.cursor),'[]'::jsonb) into result
      from (select * from assistant.events where user_id=p_user and cursor>coalesce((p_args->>'after')::bigint,0)
            order by cursor limit 200) e;
    return jsonb_build_object('events',result,'has_more',jsonb_array_length(result)=200);
  elsif p_action='bootstrap' then
    select coalesce(max(cursor),0) into current_cursor from assistant.events where user_id=p_user;
    select coalesce(jsonb_agg(to_jsonb(h) order by h.id),'[]'::jsonb) into result from
      (select id,role,content,created_at from memory.messages where role in ('user','assistant') and content is not null
        and id>coalesce((select max(id) from memory.messages where role='system' and payload->>'event'='chat_cleared'),0)
        order by id desc limit 100) h;
    return jsonb_build_object('cursor',current_cursor,'history',result,
      'replay_after',coalesce((select min(e.cursor)-1 from assistant.events e join assistant.turns active on active.id=e.turn_id
        where active.user_id=p_user and active.status='running'),current_cursor),
      'conversation_id',(select conversation_id from assistant.owner where user_id=p_user),
      'host',jsonb_build_object('online',exists(select 1 from assistant.host where lease_until>clock_timestamp()),
        'seen_at',(select seen_at from assistant.host)),
      'active_turn',(select jsonb_build_object('turn_id',id,'status',status) from assistant.turns where user_id=p_user and status in ('queued','running')));
  elsif p_action='revoke' then
    update assistant.devices set revoked_at=now() where user_id=p_user and id=(p_args->>'device_id')::uuid;
    return '{"revoked":true}';
  end if;
  raise exception 'unknown_action';
end $$;

revoke all on all functions in schema assistant from public;
grant execute on all functions in schema assistant to service_role;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
