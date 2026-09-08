create table assistant.credentials (
  user_id uuid not null references assistant.owner(user_id),
  slot text not null check(slot in ('google_connect','google_tasks','google_drive','google_contacts','todoist','notion','github')),
  ciphertext text not null,
  metadata jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key(user_id,slot)
);
create table assistant.connection_intents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references assistant.owner(user_id),
  device_id uuid not null,
  slot text not null,
  state_hash text not null unique,
  verifier text,
  state text not null default 'pending' check(state in ('pending','processing','connected','failed')),
  expires_at timestamptz not null default now()+interval '10 minutes',
  foreign key(user_id,device_id) references assistant.devices(user_id,id)
);
alter table assistant.credentials enable row level security;
alter table assistant.connection_intents enable row level security;
grant select,insert,update,delete on assistant.credentials,assistant.connection_intents to service_role;

-- Only the authenticated gateway can call this. Ciphertexts never enter its client responses.
create function public.assistant_connection_store(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare intent assistant.connection_intents; result jsonb;
begin
  if p_action='claim' then
    select * into intent from assistant.connection_intents where state_hash=p_args->>'state_hash';
    if not found or intent.state <> 'pending' or intent.expires_at <= now() then raise exception 'invalid_request' using errcode='22023'; end if;
    p_user := intent.user_id; p_device := intent.device_id;
  end if;
  perform 1 from assistant.owner where user_id=p_user for update;
  if not found then raise exception 'account_denied' using errcode='42501'; end if;
  perform assistant.require_device(p_user,p_device);
  case p_action
  when 'list' then
    select coalesce(jsonb_agg(jsonb_build_object('slot',slot,'metadata',metadata)),'[]') into result from assistant.credentials where user_id=p_user;
  when 'begin' then
    delete from assistant.connection_intents where expires_at<now()-interval '1 day';
    insert into assistant.connection_intents(user_id,device_id,slot,state_hash,verifier)
    values(p_user,p_device,p_args->>'slot',p_args->>'state_hash',p_args->>'verifier') returning jsonb_build_object('intent_id',id) into result;
  when 'claim' then
    select * into intent from assistant.connection_intents where id=intent.id for update;
    if intent.state <> 'pending' or intent.expires_at <= now() then raise exception 'invalid_request' using errcode='22023'; end if;
    update assistant.connection_intents set state='processing',verifier=null where id=intent.id;
    result := to_jsonb(intent);
  when 'status' then
    select jsonb_build_object('state',case when expires_at<now() and state in ('pending','processing') then 'failed' else state end)
    into result from assistant.connection_intents where id=(p_args->>'intent_id')::uuid and user_id=p_user and device_id=p_device;
    if not found then raise exception 'invalid_request' using errcode='22023'; end if;
  when 'complete' then
    select * into intent from assistant.connection_intents where id=(p_args->>'intent_id')::uuid and user_id=p_user and device_id=p_device for update;
    if not found or intent.state <> 'processing' or intent.expires_at <= now() then raise exception 'invalid_request' using errcode='22023'; end if;
    insert into assistant.credentials(user_id,slot,ciphertext,metadata) values(p_user,intent.slot,p_args->>'ciphertext',p_args->'metadata')
    on conflict(user_id,slot) do update set ciphertext=excluded.ciphertext,metadata=excluded.metadata,updated_at=now();
    update assistant.connection_intents set state='connected' where id=intent.id;
    result := '{}';
  when 'fail' then
    update assistant.connection_intents set state='failed',verifier=null where id=(p_args->>'intent_id')::uuid and user_id=p_user and device_id=p_device and state in ('pending','processing');
    result := '{}';
  when 'save' then
    insert into assistant.credentials(user_id,slot,ciphertext,metadata) values(p_user,p_args->>'slot',p_args->>'ciphertext',p_args->'metadata')
    on conflict(user_id,slot) do update set ciphertext=excluded.ciphertext,metadata=excluded.metadata,updated_at=now();
    result := '{}';
  when 'remove' then
    update assistant.connection_intents set state='failed',verifier=null where user_id=p_user and slot=p_args->>'slot' and state in ('pending','processing');
    delete from assistant.credentials where user_id=p_user and slot=p_args->>'slot';
    result := '{}';
  else raise exception 'invalid_request' using errcode='22023';
  end case;
  return result;
end $$;
revoke all on function public.assistant_connection_store(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_connection_store(uuid,uuid,text,jsonb) to service_role;
