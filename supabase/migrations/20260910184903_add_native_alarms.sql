-- Alarm delivery is explicit and confirmed by a registered phone, separate from task completion.
alter table memory.reminders add column alarm_at timestamptz,
 add constraint alarm_requires_exact_time check (alarm_at is null or timing='exact');
create table assistant.alarm_receipts (
 reminder_id uuid not null references memory.reminders(id) on delete cascade,
 device_id uuid not null references assistant.devices(id) on delete cascade,
 version integer not null,
 status text not null check (status in ('scheduled','cancelled','dismissed','denied','unsupported','failed','expired')),
 updated_at timestamptz not null default now(),
 primary key(reminder_id,device_id)
);
alter table assistant.alarm_receipts enable row level security;
grant select,insert,update on assistant.alarm_receipts to service_role;
create index alarm_receipts_device on assistant.alarm_receipts(device_id);

create function assistant.alarm_changed() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if (new.alarm_at is not null or (tg_op='UPDATE' and old.alarm_at is not null)) then
  if tg_op='INSERT' or new.version is distinct from old.version or new.alarm_at is distinct from old.alarm_at then
   perform assistant.emit(user_id,null,'{"type":"alarms_changed"}'::jsonb) from assistant.owner;
  end if;
 end if;
 return new;
end $$;
revoke all on function assistant.alarm_changed() from public;
create trigger alarm_changed after insert or update on memory.reminders for each row execute function assistant.alarm_changed();

alter function memory.reminder_action(jsonb) rename to reminder_action_without_alarm;
create function memory.reminder_action(p_args jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 result:=memory.reminder_action_without_alarm(p_args);
 if p_args->>'action'='snooze' then
  update memory.reminders set alarm_at=next_notify_at where id=(result->>'id')::uuid and alarm_at is not null and status='open';
  select to_jsonb(r) into result from memory.reminders r where id=(result->>'id')::uuid;
 end if;
 return result;
end $$;
revoke all on function memory.reminder_action(jsonb) from public;
grant execute on function memory.reminder_action(jsonb) to service_role;

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_before_alarms;
revoke all on function public.assistant_client_before_alarms(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare r memory.reminders;
begin
 if p_action not in ('alarm_sync','alarm_receipt') then
  return public.assistant_client_before_alarms(p_user,p_device,p_action,p_args);
 end if;
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 perform assistant.require_device(p_user,p_device);
 if p_action='alarm_receipt' then
  select * into r from memory.reminders where id=(p_args->>'id')::uuid for update;
  if not found or r.version is distinct from (p_args->>'version')::int then raise exception 'idempotency_conflict'; end if;
  if p_args->>'status'='scheduled' and (r.status<>'open' or r.alarm_at is null) then raise exception 'invalid_request'; end if;
  insert into assistant.alarm_receipts(reminder_id,device_id,version,status) values(r.id,p_device,r.version,p_args->>'status')
   on conflict(reminder_id,device_id) do update set version=excluded.version,status=excluded.status,updated_at=now();
  return '{"saved":true}'::jsonb;
 end if;
 return jsonb_build_object('alarms',coalesce((select jsonb_agg(jsonb_build_object('id',rem.id,'title',rem.title,'version',rem.version,
   'alarm_at',rem.alarm_at,'enabled',rem.status='open' and rem.alarm_at is not null,'receipt',a.status,'receipt_version',a.version))
  from memory.reminders rem left join assistant.alarm_receipts a on a.reminder_id=rem.id and a.device_id=p_device
  where (rem.status='open' and rem.alarm_at is not null) or (a.status is not null and a.status not in ('cancelled','dismissed'))),'[]'::jsonb));
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
