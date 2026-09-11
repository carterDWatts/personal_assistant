-- Durable work, coalesced per plan. The model cannot silently skip a selected row.
create table memory.plan_reviews (
  plan_id bigint primary key references memory.plans(id) on delete cascade,
  requested_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  available_at timestamptz not null default now(),
  receipt jsonb,
  last_error text
);
alter table memory.plan_reviews enable row level security;
revoke all on memory.plan_reviews from public,anon,authenticated;
grant all on memory.plan_reviews to service_role;
create function memory.queue_plan_reviews() returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if current_setting('assistant.reconciling_plans',true)='on' then return new; end if;
  insert into memory.plan_reviews(plan_id)
    select id from memory.plans where superseded_by is null and status in ('planned','partial','proposed')
    on conflict(plan_id) do update set requested_at=clock_timestamp();
  return new;
end $$;
revoke all on function memory.queue_plan_reviews() from public;
create trigger plans_need_review after insert or update on memory.plans
  for each row execute function memory.queue_plan_reviews();
create trigger extracted_evidence_reviews_plans after update of status on memory.memory_jobs
  for each row when (new.status='done' and old.status is distinct from new.status)
  execute function memory.queue_plan_reviews();
insert into memory.plan_reviews(plan_id)
  select id from memory.plans where superseded_by is null and status in ('planned','partial','proposed');
