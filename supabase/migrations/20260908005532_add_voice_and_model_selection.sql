alter table assistant.host add column capabilities jsonb not null default '{}';
alter table assistant.turns add column model text;
alter table assistant.turns add column speech boolean not null default false;

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v2;
revoke all on function public.assistant_client_v2(uuid,uuid,text,jsonb) from public;

create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; caps jsonb; old assistant.turns; wanted text; speaking boolean;
begin
  perform 1 from assistant.owner where user_id=p_user for update;
  if not found then raise exception 'account_denied' using errcode='42501'; end if;
  if p_action <> 'register' then perform assistant.require_device(p_user,p_device); end if;
  select capabilities into caps from assistant.host;
  caps := coalesce(caps,'{}');
  if p_action='submit' then
    wanted := nullif(p_args->>'model','');
    if p_args ? 'speech' and jsonb_typeof(p_args->'speech') <> 'boolean' then
      raise exception 'invalid_request' using errcode='22023';
    end if;
    speaking := coalesce((p_args->>'speech')::boolean,false);
    select * into old from assistant.turns where user_id=p_user and client_message_id=(p_args->>'client_message_id')::uuid;
    if found then
      if old.model is distinct from wanted or old.speech <> speaking then raise exception 'idempotency_conflict'; end if;
    else
      if wanted is not null and not exists(select 1 from jsonb_array_elements(coalesce(caps->'models','[]')) m where m->>'id'=wanted) then
        raise exception 'model_unavailable' using errcode='22023';
      end if;
      if speaking and coalesce((caps->>'speech')::boolean,false)=false then
        raise exception 'speech_unavailable' using errcode='22023';
      end if;
    end if;
    result := public.assistant_client_v2(p_user,p_device,p_action,p_args);
    update assistant.turns set model=wanted,speech=speaking where id=(result->>'turn_id')::uuid;
    return result;
  elsif p_action='cancel' then
    -- Speech can still be streaming after the text has finished.
    update assistant.turns set cancel_requested=true where user_id=p_user and id=(p_args->>'turn_id')::uuid and status='completed';
  end if;
  result := public.assistant_client_v2(p_user,p_device,p_action,p_args);
  if p_action='bootstrap' then result := result || jsonb_build_object('capabilities',caps); end if;
  return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;

create table assistant.speech_objects(path text primary key, created_at timestamptz not null default now());
create index speech_expiration on assistant.speech_objects(created_at);
alter table assistant.speech_objects enable row level security;
grant select,insert,delete on assistant.speech_objects to service_role;
