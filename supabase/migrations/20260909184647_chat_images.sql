create table assistant.images (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references assistant.owner(user_id) on delete cascade,
  path text not null unique,
  name text not null check(length(name) between 1 and 160),
  mime text not null check(mime in ('image/jpeg','image/png','image/webp')),
  bytes integer not null check(bytes between 1 and 4000000),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  ready boolean not null default false,
  source_url text,
  created_at timestamptz not null default now()
);
create index images_owner on assistant.images(user_id,created_at desc);
alter table assistant.images enable row level security;
grant select,insert,update,delete on assistant.images to service_role;
alter table assistant.turns add column images uuid[] not null default '{}';

create function public.assistant_image(p_user uuid,p_device uuid,p_action text,p_args jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare img assistant.images; image_id uuid:=(p_args->>'id')::uuid;
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 perform assistant.require_device(p_user,p_device);
 if p_action='reserve' then
   insert into assistant.images(id,user_id,path,name,mime,bytes,sha256)
    values(image_id,p_user,p_user::text||'/'||image_id::text,p_args->>'name',p_args->>'mime',(p_args->>'bytes')::integer,p_args->>'sha256') on conflict(id) do nothing;
 end if;
 select * into img from assistant.images where id=image_id and user_id=p_user for update;
 if not found then raise exception 'invalid_request' using errcode='22023'; end if;
 if p_action='reserve' then
   if img.sha256 is distinct from p_args->>'sha256' then raise exception 'idempotency_conflict'; end if;
 elsif p_action='complete' then
   update assistant.images set ready=true where id=image_id returning * into img;
 elsif p_action='get' then
   if not img.ready then raise exception 'invalid_request' using errcode='22023'; end if;
 else raise exception 'invalid_request' using errcode='22023'; end if;
 return to_jsonb(img);
end $$;
revoke all on function public.assistant_image(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_image(uuid,uuid,text,jsonb) to service_role;

alter function public.assistant_client(uuid,uuid,text,jsonb) rename to assistant_client_v9;
revoke all on function public.assistant_client_v9(uuid,uuid,text,jsonb) from public;
create function public.assistant_client(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare result jsonb; previous assistant.turns; wanted uuid[];
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 if p_action<>'register' then perform assistant.require_device(p_user,p_device); end if;
 if p_action='submit' then
   wanted:=array(select jsonb_array_elements_text(coalesce(p_args->'images','[]'::jsonb))::uuid);
   if cardinality(wanted)>4 or cardinality(wanted)<>(select count(distinct i) from unnest(wanted) i) or exists(
     select 1 from unnest(wanted) i where not exists(select 1 from assistant.images where id=i and user_id=p_user and ready)
   ) then raise exception 'invalid_request' using errcode='22023'; end if;
   select * into previous from assistant.turns where user_id=p_user and device_id=p_device and client_message_id=(p_args->>'client_message_id')::uuid;
   if found and previous.images is distinct from wanted then raise exception 'idempotency_conflict'; end if;
 end if;
 result:=public.assistant_client_v9(p_user,p_device,p_action,p_args);
 if p_action='submit' then update assistant.turns set images=wanted where id=(result->>'turn_id')::uuid; end if;
 return result;
end $$;
revoke all on function public.assistant_client(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_client(uuid,uuid,text,jsonb) to service_role;
