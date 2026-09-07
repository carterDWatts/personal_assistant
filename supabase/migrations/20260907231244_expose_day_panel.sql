-- The owner's time zone governs the day even when the gateway runs in UTC.
alter table assistant.owner add column timezone text not null default 'America/Los_Angeles';

create function assistant.day_snapshot() returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object(
    'day',(now() at time zone (select timezone from assistant.owner))::date,
    'learned',coalesce((select jsonb_agg(to_jsonb(a) order by a.recorded_at desc) from
      (select entity_name,attribute,value,recorded_at from memory.current_assertions order by recorded_at desc limit 8) a),'[]'::jsonb),
    'plans',coalesce((select jsonb_agg(jsonb_build_object('item',item,'status',status) order by id)
      from memory.plans where day=(now() at time zone (select timezone from assistant.owner))::date),'[]'::jsonb),
    'questions',(select count(*) from memory.questions where closed_at is null),
    'pending',(select count(*) from memory.memory_jobs where status<>'done'),
    'errors',(select count(*) from memory.memory_jobs where status='error'))
$$;
revoke all on function assistant.day_snapshot() from public;
grant execute on function assistant.day_snapshot() to service_role;

-- Keep the original dispatch private; authorization still precedes every read.
alter function public.assistant_client(uuid,uuid,text,jsonb) set schema assistant;
alter function assistant.assistant_client(uuid,uuid,text,jsonb) rename to client_base;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
  result := assistant.client_base(p_user,p_device,p_action,p_args);
  if p_action='bootstrap' then
    result := result || jsonb_build_object('day',assistant.day_snapshot());
  end if;
  return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
