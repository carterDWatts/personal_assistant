alter table assistant.credentials drop constraint credentials_slot_check;
alter table assistant.credentials add constraint credentials_slot_check
  check(slot in ('google_connect','google_tasks','google_drive','google_contacts','todoist','notion','github','supabase','spotify'));

-- A command belongs to the phone that submitted this turn. Claim once; never replay
-- playback after a crash, cancellation or host replacement.
create table assistant.spotify_commands (
  id uuid primary key,
  user_id uuid not null,
  device_id uuid not null,
  turn_id uuid not null,
  command jsonb not null check(jsonb_typeof(command)='object'),
  expires_at timestamptz not null default now()+interval '100 seconds',
  claimed_at timestamptz,
  result jsonb check(jsonb_typeof(result)='object' and octet_length(result::text)<=4096),
  foreign key(user_id,device_id) references assistant.devices(user_id,id),
  foreign key(user_id,turn_id) references assistant.turns(user_id,id)
);
create index spotify_commands_turn on assistant.spotify_commands(user_id,turn_id);
create index spotify_commands_device on assistant.spotify_commands(user_id,device_id);
alter table assistant.spotify_commands enable row level security;
grant select,insert,update,delete on assistant.spotify_commands to service_role;

create function public.assistant_spotify(p_user uuid,p_device uuid,p_action text,p_args jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare c assistant.spotify_commands;
begin
  perform 1 from assistant.owner where user_id=p_user for update;
  if not found then raise exception 'account_denied' using errcode='42501'; end if;
  perform assistant.require_device(p_user,p_device);
  select * into c from assistant.spotify_commands
    where id=(p_args->>'command_id')::uuid and user_id=p_user and device_id=p_device for update;
  if not found then raise exception 'invalid_request' using errcode='22023'; end if;
  if c.expires_at<=clock_timestamp() or not exists(
    select 1 from assistant.turns t,assistant.host h where t.id=c.turn_id and t.device_id=p_device
      and t.status='running' and not t.cancel_requested and t.worker_id=h.worker_id and h.lease_until>clock_timestamp()
  ) then return jsonb_build_object('state','expired'); end if;
  if p_action='claim' then
    if not exists(select 1 from assistant.credentials where user_id=p_user and slot='spotify') then
      raise exception 'invalid_request' using errcode='22023';
    end if;
    if c.claimed_at is not null then return jsonb_build_object('state','claimed'); end if;
    update assistant.spotify_commands set claimed_at=clock_timestamp() where id=c.id;
    delete from assistant.spotify_commands where expires_at<now()-interval '1 day';
    return jsonb_build_object('state','ready','command',c.command,'expires_at',c.expires_at);
  elsif p_action='finish' then
    if c.claimed_at is null then raise exception 'invalid_request' using errcode='22023'; end if;
    if c.result is null then
      if jsonb_typeof(p_args->'result') is distinct from 'object' then raise exception 'invalid_request' using errcode='22023'; end if;
      update assistant.spotify_commands set result=p_args->'result' where id=c.id;
      perform pg_notify('assistant_commands',c.id::text);
    end if;
    return jsonb_build_object('state','finished');
  end if;
  raise exception 'invalid_request' using errcode='22023';
end $$;
revoke all on function public.assistant_spotify(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_spotify(uuid,uuid,text,jsonb) to service_role;
