-- A reply stays in the conversation. Push delivery is separate from the inbox.
create table assistant.reply_deliveries (
 id uuid primary key default gen_random_uuid(),
 turn_id uuid not null unique references assistant.turns(id) on delete cascade,
 device_id uuid not null references assistant.devices(id) on delete cascade,
 end_cursor bigint not null references assistant.events(cursor) on delete cascade,
 retry_at timestamptz not null default now()+interval '5 seconds',
 sent_at timestamptz,
 cancelled_at timestamptz,
 last_error text
);
create index reply_deliveries_pending on assistant.reply_deliveries(retry_at) where sent_at is null and cancelled_at is null;
alter table assistant.reply_deliveries enable row level security;
revoke all on assistant.reply_deliveries from public,anon,authenticated;
grant select,insert,update,delete on assistant.reply_deliveries to service_role;

create function assistant.queue_reply() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 insert into assistant.reply_deliveries(turn_id,device_id,end_cursor)
 select t.id,t.device_id,new.cursor from assistant.turns t
 join assistant.push_devices p on p.device_id=t.device_id
 join assistant.devices d on d.id=t.device_id
 where t.id=new.turn_id and t.user_id=new.user_id and p.enabled and d.revoked_at is null
 on conflict(turn_id) do nothing;
 return new;
end $$;
revoke all on function assistant.queue_reply() from public;
create trigger queue_reply after insert on assistant.events for each row
 when (new.payload->>'type'='end' and new.payload->>'status' in ('completed','failed'))
 execute function assistant.queue_reply();

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_before_replies;
revoke all on function public.assistant_client_before_replies(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
begin
 if p_action='reply_seen' then
  perform assistant.require_device(p_user,p_device);
  if jsonb_typeof(p_args->'cursor') is distinct from 'number' or (p_args->>'cursor')::bigint<0 then
   raise exception 'invalid_request' using errcode='22023';
  end if;
  update assistant.reply_deliveries set cancelled_at=now()
   where device_id=p_device and end_cursor<=(p_args->>'cursor')::bigint and cancelled_at is null;
  return '{"seen":true}';
 end if;
 return public.assistant_client_before_replies(p_user,p_device,p_action,p_args);
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
