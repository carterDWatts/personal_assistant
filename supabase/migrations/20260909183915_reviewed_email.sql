alter table assistant.credentials drop constraint credentials_slot_check;
alter table assistant.credentials add constraint credentials_slot_check
  check(slot in ('google_connect','google_tasks','google_drive','google_contacts','google_mail_send','todoist','notion','github','supabase','spotify'));

create table assistant.email_drafts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references assistant.owner(user_id) on delete cascade,
  source_message bigint references memory.messages(id) on delete set null,
  payload jsonb not null check(jsonb_typeof(payload)='object' and octet_length(payload::text)<=100000),
  version integer not null default 1,
  content_hash text not null,
  state text not null default 'draft' check(state in ('draft','queued','sending','sent','failed','uncertain','discarded')),
  approved_hash text,
  approved_device uuid,
  approved_at timestamptz,
  sending_at timestamptz,
  receipt jsonb,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(user_id,approved_device) references assistant.devices(user_id,id)
);
create index email_drafts_owner on assistant.email_drafts(user_id,created_at desc);
create index email_drafts_queue on assistant.email_drafts(created_at) where state='queued';
alter table assistant.email_drafts enable row level security;
grant select,insert,update on assistant.email_drafts to service_role;

create function assistant.guard_email_draft() returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='UPDATE' then
    if new.user_id<>old.user_id or new.id<>old.id then raise exception 'immutable_draft_owner'; end if;
    if new.payload<>old.payload then
      if old.state<>'draft' or new.state<>'draft' then raise exception 'draft_locked'; end if;
      new.version:=old.version+1;
      new.approved_at:=null; new.approved_hash:=null; new.approved_device:=null;
    else new.version:=old.version; end if;
  end if;
  new.content_hash:=encode(sha256(convert_to(new.payload::text,'UTF8')),'hex');
  if new.state in ('queued','sending','sent') and
    (new.approved_at is null or new.approved_hash is distinct from new.content_hash) then
    raise exception 'draft_not_approved';
  end if;
  new.updated_at:=clock_timestamp();
  return new;
end $$;
create trigger guard_email_draft before insert or update on assistant.email_drafts for each row execute function assistant.guard_email_draft();

-- This endpoint is invoked by the authenticated gateway, never registered as a model tool.
create function public.assistant_email(p_user uuid,p_device uuid,p_action text,p_args jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare d assistant.email_drafts;
begin
  perform 1 from assistant.owner where user_id=p_user for update;
  if not found then raise exception 'account_denied' using errcode='42501'; end if;
  perform assistant.require_device(p_user,p_device);
  if p_action='list' then
    return jsonb_build_object('drafts',coalesce((select jsonb_agg(to_jsonb(r)) from
      (select * from assistant.email_drafts where user_id=p_user and state<>'discarded' order by created_at desc limit 30) r),'[]'::jsonb));
  end if;
  select * into d from assistant.email_drafts where id=(p_args->>'id')::uuid and user_id=p_user for update;
  if not found then raise exception 'invalid_request' using errcode='22023'; end if;
  if p_action='get' then return to_jsonb(d); end if;
  if d.version is distinct from (p_args->>'version')::integer or d.content_hash is distinct from p_args->>'content_hash' then
    raise exception 'draft_changed' using errcode='40001';
  end if;
  if p_action='approve' and d.state in ('queued','sending','sent','uncertain') then return to_jsonb(d); end if;
  if d.state<>'draft' then raise exception 'draft_locked' using errcode='22023'; end if;
  if p_action='approve' then
    if d.updated_at<now()-interval '1 day' then raise exception 'draft_expired' using errcode='22023'; end if;
    update assistant.email_drafts set state='queued',approved_hash=content_hash,approved_at=clock_timestamp(),approved_device=p_device where id=d.id returning * into d;
    perform pg_notify('assistant_commands',d.id::text);
  elsif p_action='discard' then
    update assistant.email_drafts set state='discarded' where id=d.id returning * into d;
  else raise exception 'invalid_request' using errcode='22023'; end if;
  return to_jsonb(d);
end $$;
revoke all on function public.assistant_email(uuid,uuid,text,jsonb) from public;
grant execute on function public.assistant_email(uuid,uuid,text,jsonb) to service_role;
revoke all on function assistant.guard_email_draft() from public;
