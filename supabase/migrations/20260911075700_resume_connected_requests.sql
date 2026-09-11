alter table assistant.turns drop constraint turns_invocation_check;
alter table assistant.turns add constraint turns_invocation_check check(invocation in ('morning','review','connection'));
create table assistant.connection_waits (
 turn_id uuid not null references assistant.turns(id) on delete cascade,
 action text not null,
 slot text not null,
 scopes text[] not null default '{}',
 ready boolean not null default false,
 resumed_turn uuid references assistant.turns(id),
 primary key(turn_id,action)
);
alter table assistant.connection_waits enable row level security;
revoke all on assistant.connection_waits from public,anon,authenticated;
grant select,insert,update,delete on assistant.connection_waits to service_role;

create function assistant.capture_connection_wait() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.turn_id is not null and new.payload->>'type'='connection_required' and new.payload->>'slot' is not null then
  insert into assistant.connection_waits(turn_id,action,slot,scopes)
   values(new.turn_id,new.payload->>'action',new.payload->>'slot',array(select jsonb_array_elements_text(coalesce(new.payload->'scopes','[]'))))
   on conflict do nothing;
 end if;
 return new;
end $$;
create trigger capture_connection_wait after insert on assistant.events for each row execute function assistant.capture_connection_wait();

alter function public.assistant_connection_store(uuid,uuid,text,jsonb) rename to assistant_connection_store_before_resume;
revoke all on function public.assistant_connection_store_before_resume(uuid,uuid,text,jsonb) from public;
create function public.assistant_connection_store(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; connected_slot text;
begin
 result:=public.assistant_connection_store_before_resume(p_user,p_device,p_action,p_args);
 if p_action in ('complete','save') then
  if p_action='complete' then select slot into connected_slot from assistant.connection_intents where id=(p_args->>'intent_id')::uuid;
  else connected_slot:=p_args->>'slot'; end if;
  update assistant.connection_waits w set ready=true from assistant.turns t
   where w.turn_id=t.id and t.user_id=p_user and t.device_id=p_device and w.slot=connected_slot
   and w.resumed_turn is null and w.scopes <@ array(select jsonb_array_elements_text(coalesce(p_args->'metadata'->'scopes','[]')));
 end if;
 return result;
end $$;

create function assistant.resume_connection() returns void language plpgsql security invoker set search_path='' as $$
declare waiting record; resumed uuid;
begin
 perform 1 from assistant.owner for update;
 if exists(select 1 from assistant.turns where status in ('queued','running')) then return; end if;
 select w.*,t.user_id,t.device_id,t.model into waiting from assistant.connection_waits w join assistant.turns t on t.id=w.turn_id
  join assistant.devices d on d.id=t.device_id and d.revoked_at is null
  where w.ready and w.resumed_turn is null and t.status in ('completed','failed') and not t.cancel_requested
   and not exists(select 1 from assistant.turns newer where newer.user_id=t.user_id and newer.created_at>t.created_at and newer.invocation is distinct from 'connection')
   and not exists(select 1 from memory.messages m where m.payload->>'event'='chat_cleared' and m.created_at>t.created_at)
  order by t.created_at desc limit 1 for update of w;
 if not found then return; end if;
 insert into assistant.turns(user_id,device_id,client_message_id,text,model,invocation)
  values(waiting.user_id,waiting.device_id,gen_random_uuid(),
   'Connection confirmed for '||waiting.action||'. Continue only the step that was waiting for this access. Check prior tool results and do not repeat actions already performed. All existing send confirmations still apply.',waiting.model,'connection') returning id into resumed;
 update assistant.connection_waits set resumed_turn=resumed where turn_id=waiting.turn_id and action=waiting.action;
 perform assistant.emit(waiting.user_id,resumed,jsonb_build_object('type','connection_resumed','action',waiting.action));
end $$;
revoke all on function assistant.capture_connection_wait(),assistant.resume_connection(),public.assistant_connection_store(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function assistant.capture_connection_wait(),assistant.resume_connection(),public.assistant_connection_store(uuid,uuid,text,jsonb),public.assistant_connection_store_before_resume(uuid,uuid,text,jsonb) to service_role;
