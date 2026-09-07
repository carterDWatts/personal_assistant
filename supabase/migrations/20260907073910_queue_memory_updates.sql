-- The transcript is durable immediately; structured extraction is asynchronous.
alter table memory.conversations add column runtime_policy_version integer not null default 1;
create table memory.memory_jobs (
  message_id bigint primary key references memory.messages(id),
  status text not null default 'pending' check (status in ('pending','processing','done','error')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  completed_at timestamptz,
  last_error text,
  metrics jsonb not null default '{}'::jsonb
);
alter table memory.memory_jobs enable row level security;
create index memory_jobs_pending on memory.memory_jobs(message_id) where status <> 'done';
grant select,insert,update on memory.memory_jobs to service_role;

create function memory.queue_message() returns trigger language plpgsql as $$
begin
  if new.role = 'user' and new.content is not null and exists (
    select 1 from memory.conversations where id=new.conversation_id and runtime_policy_version >= 3
  ) then
    insert into memory.memory_jobs(message_id) values(new.id) on conflict do nothing;
  end if;
  return new;
end $$;
create trigger messages_queue_memory after insert on memory.messages
  for each row execute function memory.queue_message();
revoke execute on function memory.queue_message() from public;
