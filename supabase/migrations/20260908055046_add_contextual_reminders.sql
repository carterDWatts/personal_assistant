create table memory.reminders (
 id uuid primary key default gen_random_uuid(),
 title text not null check (length(title) between 1 and 300),
 context text not null default '' check (length(context)<=5000),
 status text not null default 'open' check (status in ('open','completed','cancelled')),
 timing text not null check (timing in ('exact','day','week','someday')),
 window_start timestamptz not null,
 window_end timestamptz,
 next_notify_at timestamptz not null,
 followup_hours numeric not null check (followup_hours between 0.25 and 168),
 timezone text not null,
 source_message_id bigint references memory.messages(id),
 completion_message_id bigint references memory.messages(id),
 completed_at timestamptz,
 version integer not null default 1,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 check (window_end is null or window_end>=window_start)
);
alter table memory.reminders enable row level security;
grant select,insert,update on memory.reminders to service_role;
create index reminders_due on memory.reminders(next_notify_at) where status='open';
create trigger context_changed after insert or update or delete on memory.reminders for each statement execute function memory.invalidate_context();

create table assistant.push_devices (
 device_id uuid primary key references assistant.devices(id) on delete cascade,
 token text not null check (token ~ '^[0-9a-f]{64,200}$'),
 environment text not null check (environment in ('sandbox','production')),
 enabled boolean not null default true,
 updated_at timestamptz not null default now()
);
create table assistant.reminder_deliveries (
 id uuid primary key default gen_random_uuid(),
 reminder_id uuid not null references memory.reminders(id) on delete cascade,
 device_id uuid not null references assistant.devices(id) on delete cascade,
 scheduled_at timestamptz not null,
 version integer not null,
 sent_at timestamptz,
 cancelled_at timestamptz,
 last_error text,
 attempts integer not null default 0,
 retry_at timestamptz not null default now(),
 unique(reminder_id,device_id,scheduled_at)
);
alter table assistant.push_devices enable row level security;
alter table assistant.reminder_deliveries enable row level security;
grant select,insert,update on assistant.push_devices,assistant.reminder_deliveries to service_role;
create index reminder_delivery_pending on assistant.reminder_deliveries(retry_at) where sent_at is null and cancelled_at is null;

create function memory.reminder_action(p_args jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare r memory.reminders; operation text:=p_args->>'action'; until_time timestamptz;
begin
 select * into r from memory.reminders where id=(p_args->>'id')::uuid for update;
 if not found then raise exception 'invalid_request' using errcode='22023'; end if;
 if r.version=(p_args->>'version')::integer+1 and ((operation='done' and r.status='completed') or (operation='cancel' and r.status='cancelled') or (operation='snooze' and r.next_notify_at=(p_args->>'until')::timestamptz)) then return to_jsonb(r); end if;
 if r.version is distinct from (p_args->>'version')::integer then raise exception 'idempotency_conflict'; end if;
 if operation='done' then
   update memory.reminders set status='completed',completed_at=now(),completion_message_id=(p_args->>'message_id')::bigint,version=version+1,updated_at=now() where id=r.id;
 elsif operation='cancel' then
   update memory.reminders set status='cancelled',version=version+1,updated_at=now() where id=r.id;
 elsif operation='snooze' then
   until_time := (p_args->>'until')::timestamptz;
   if until_time is null or until_time<=now() then raise exception 'invalid_request' using errcode='22023'; end if;
   update memory.reminders set next_notify_at=until_time,version=version+1,updated_at=now() where id=r.id and status='open';
 else raise exception 'invalid_request' using errcode='22023'; end if;
 return (select to_jsonb(x) from memory.reminders x where id=r.id);
end $$;
revoke all on function memory.reminder_action(jsonb) from public;
grant execute on function memory.reminder_action(jsonb) to service_role;

alter function assistant.day_snapshot() rename to day_snapshot_v1;
create function assistant.day_snapshot() returns jsonb language sql stable security invoker set search_path='' as $$
 select assistant.day_snapshot_v1() || jsonb_build_object('reminders',coalesce((select jsonb_agg(x order by x.next_notify_at) from
 (select * from memory.reminders where status='open' order by next_notify_at limit 100) x),'[]'::jsonb))
$$;
revoke all on function assistant.day_snapshot() from public;
grant execute on function assistant.day_snapshot() to service_role;

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v5;
revoke all on function public.assistant_client_v5(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action <> 'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='push_register' then
   insert into assistant.push_devices(device_id,token,environment,enabled) values(p_device,p_args->>'token',p_args->>'environment',true)
   on conflict(device_id) do update set token=excluded.token,environment=excluded.environment,enabled=true,updated_at=now();
   return '{"saved":true}'::jsonb;
 elsif p_action='reminder_action' then
   perform memory.reminder_action(p_args - 'message_id');
   return assistant.day_snapshot();
 elsif p_action='reminders' then return assistant.day_snapshot(); end if;
 return public.assistant_client_v5(p_user,p_device,p_action,p_args);
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
