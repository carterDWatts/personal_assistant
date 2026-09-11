alter table memory.plans
  add column version integer not null default 1,
  add column updated_at timestamptz not null default now(),
  add column superseded_by bigint references memory.plans(id),
  add column last_observation_id bigint references memory.observations(id),
  add constraint plans_not_self_superseded check (superseded_by is distinct from id);

create table memory.plan_revisions (
  id bigint generated always as identity primary key,
  plan_id bigint not null references memory.plans(id),
  recorded_at timestamptz not null default clock_timestamp(),
  previous jsonb not null,
  replacement jsonb not null
);
alter table memory.plan_revisions enable row level security;
create index plan_revisions_plan on memory.plan_revisions(plan_id,recorded_at);
create trigger plan_revisions_immutable before update or delete on memory.plan_revisions
  for each row execute function memory.protect_revision();
create function memory.revise_plan() returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if old is distinct from new then
    new.version := old.version + 1;
    new.updated_at := clock_timestamp();
    insert into memory.plan_revisions(plan_id,previous,replacement) values(old.id,to_jsonb(old),to_jsonb(new));
  end if;
  return new;
end $$;
create trigger plans_revision before update on memory.plans for each row execute function memory.revise_plan();
revoke all on function memory.revise_plan() from public;

create index plans_unresolved on memory.plans(day,id)
  where superseded_by is null and status in ('planned','partial','proposed');

create function memory.plan_notes(p_day date) returns table (
  id bigint, day date, item text, status text, section text, version integer, outcome_note text
) language sql stable security invoker set search_path='' as $$
  select p.id,p.day,p.item,p.status,
    case when p.status in ('done','skipped','dropped') then 'finished'
         when p.day<p_day then 'review' when p.day>p_day then 'upcoming' else 'current' end,
    p.version,p.outcome_note
  from memory.plans p where p.superseded_by is null and
    (p.status in ('planned','partial','proposed') and p.day<=p_day+7 or p.day=p_day)
  order by case when p.status in ('done','skipped','dropped') then 3
                when p.day=p_day then 0 when p.day<p_day then 1 else 2 end,p.day,p.id
  limit 100
$$;
revoke all on function memory.plan_notes(date) from public;
grant execute on function memory.plan_notes(date) to service_role;
grant select,insert on memory.plan_revisions to service_role;
grant usage,select on sequence memory.plan_revisions_id_seq to service_role;

-- Preserve the other day-panel fields and its existing authorization boundary.
alter function assistant.day_snapshot() rename to day_snapshot_before_plan_notes;
create function assistant.day_snapshot() returns jsonb
language sql stable security invoker set search_path='' as $$
  select assistant.day_snapshot_before_plan_notes() || jsonb_build_object('plans',
    coalesce((select jsonb_agg(to_jsonb(p)) from memory.plan_notes(
      (now() at time zone (select timezone from assistant.owner))::date) p),'[]'::jsonb))
$$;
revoke all on function assistant.day_snapshot() from public;
grant execute on function assistant.day_snapshot() to service_role;
