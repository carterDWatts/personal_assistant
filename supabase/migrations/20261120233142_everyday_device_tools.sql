-- A command belongs to the phone that submitted this turn. Claim once; never replay
-- a command after a crash, cancellation or host replacement.
create table assistant.device_commands (
  id uuid primary key,
  user_id uuid not null,
  device_id uuid not null,
  turn_id uuid not null,
  command jsonb not null check(jsonb_typeof(command)='object' and coalesce(command->>'action' in ('places','route','location','location_reminder'),false)),
  expires_at timestamptz not null default now()+interval '100 seconds',
  claimed_at timestamptz,
  result jsonb check(jsonb_typeof(result)='object' and octet_length(result::text)<=32000),
  foreign key(user_id,device_id) references assistant.devices(user_id,id),
  foreign key(user_id,turn_id) references assistant.turns(user_id,id)
);
create index device_commands_turn on assistant.device_commands(user_id,turn_id);
create index device_commands_device on assistant.device_commands(user_id,device_id);
alter table assistant.device_commands enable row level security;
revoke all on assistant.device_commands from anon,authenticated;
grant select,insert,update,delete on assistant.device_commands to service_role;

create function public.assistant_device(p_user uuid,p_device uuid,p_action text,p_args jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare c assistant.device_commands;
begin
  perform 1 from assistant.owner where user_id=p_user for update;
  if not found then raise exception 'account_denied' using errcode='42501'; end if;
  perform assistant.require_device(p_user,p_device);
  select * into c from assistant.device_commands
    where id=(p_args->>'command_id')::uuid and user_id=p_user and device_id=p_device for update;
  if not found then raise exception 'invalid_request' using errcode='22023'; end if;
  if c.expires_at<=clock_timestamp() or not exists(
    select 1 from assistant.turns t,assistant.host h where t.id=c.turn_id and t.device_id=p_device
      and t.status='running' and not t.cancel_requested and t.worker_id=h.worker_id and h.lease_until>clock_timestamp()
  ) then return jsonb_build_object('state','expired'); end if;
  if p_action='claim' then
    if c.claimed_at is not null then return jsonb_build_object('state','claimed'); end if;
    update assistant.device_commands set claimed_at=clock_timestamp() where id=c.id;
    delete from assistant.device_commands where expires_at<now()-interval '1 day';
    return jsonb_build_object('state','ready','command',c.command,'expires_at',c.expires_at);
  elsif p_action='finish' then
    if c.claimed_at is null then raise exception 'invalid_request' using errcode='22023'; end if;
    if c.result is null then
      if jsonb_typeof(p_args->'result') is distinct from 'object' then raise exception 'invalid_request' using errcode='22023'; end if;
      update assistant.device_commands set result=p_args->'result' where id=c.id;
      perform pg_notify('assistant_commands',c.id::text);
    end if;
    return jsonb_build_object('state','finished');
  end if;
  raise exception 'invalid_request' using errcode='22023';
end $$;
revoke all on function public.assistant_device(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_device(uuid,uuid,text,jsonb) to service_role;

-- Keep editing grants separate from the existing read grants.
alter table assistant.credentials drop constraint credentials_slot_check;
alter table assistant.credentials add constraint credentials_slot_check check(slot in
 ('google_connect','google_tasks','google_drive','google_contacts','google_mail_send','google_documents_write','google_tasks_write','todoist','notion','github','supabase','spotify','plaid'));
create table assistant.external_operations (
 key text primary key,
 operation text not null,
 state text not null default 'running' check(state in ('running','completed','uncertain')),
 result jsonb,
 created_at timestamptz not null default now()
);
alter table assistant.external_operations enable row level security;
revoke all on assistant.external_operations from anon,authenticated;
grant select,insert,update,delete on assistant.external_operations to service_role;

-- Supabase's default privileges can grant anon/authenticated directly even after
-- REVOKE FROM PUBLIC. Only the authenticated gateway may call assistant RPCs.
do $$ declare f record; begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname like 'assistant\_%' escape '\' loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  execute format('grant execute on function %s to service_role',f.signature);
 end loop;
end $$;

create table assistant.price_watches (
 id uuid primary key default gen_random_uuid(),
 url text not null check(length(url)<=2048),
 offer_key text not null,
 title text not null,
 currency text not null,
 threshold numeric not null check(threshold>=0),
 last_price numeric,
 generation integer not null default 1,
 enabled boolean not null default true,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '90 days',
 next_check timestamptz not null default now(),
 last_checked timestamptz,
 last_error text,
 notified_at timestamptz,
 unique(url,offer_key)
);
create index price_watches_due on assistant.price_watches(next_check) where enabled and notified_at is null;
alter table assistant.price_watches enable row level security;
revoke all on assistant.price_watches from anon,authenticated;
grant select,insert,update,delete on assistant.price_watches to service_role;

alter table memory.reminders add column location_trigger jsonb;
create function public.assistant_locations(p_user uuid,p_device uuid,p_action text,p_args jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 perform 1 from assistant.owner where user_id=p_user;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 perform assistant.require_device(p_user,p_device);
 if p_action='sync' then
  return jsonb_build_object('reminders',coalesce((select jsonb_agg(jsonb_build_object('id',id,'version',version,'title',title,'trigger',location_trigger))
   from memory.reminders where status='open' and location_trigger->>'device_id'=p_device::text),'[]'::jsonb));
 elsif p_action in ('delivered','unscheduled') then
  update memory.reminders set location_trigger=null,next_notify_at=now()+followup_hours*interval '1 hour'
   where id=(p_args->>'id')::uuid and version=(p_args->>'version')::integer and status='open'
     and location_trigger->>'device_id'=p_device::text;
  return jsonb_build_object('recorded',found);
 end if;
 raise exception 'invalid_request' using errcode='22023';
end $$;
revoke all on function public.assistant_locations(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.assistant_locations(uuid,uuid,text,jsonb) to service_role;

create function assistant.clear_changed_location_reminder() returns trigger language plpgsql set search_path='' as $$
begin
 if new.version<>old.version and new.location_trigger is not distinct from old.location_trigger then
   new.location_trigger=null;
 end if;
 return new;
end $$;
create trigger clear_changed_location_reminder before update on memory.reminders
 for each row execute function assistant.clear_changed_location_reminder();
revoke all on function assistant.clear_changed_location_reminder() from public,anon,authenticated;

create or replace view memory.active_reminders with(security_invoker=true) as
 select * from memory.reminders m where status='open' and
 (kind='task' or (window_end>now() and not exists(select 1 from assistant.reminder_deliveries d where d.reminder_id=m.id and d.version=m.version and d.sent_at is not null)));
