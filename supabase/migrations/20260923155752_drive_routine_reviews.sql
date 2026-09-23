-- A review decision changes attention, never the truth or completion of its subject.
create table memory.review_decisions (
 id bigint generated always as identity primary key,
 kind text not null check(kind in ('question','plan')),
 ref_id text not null,
 revision text not null,
 action text not null check(action in ('keep','defer','dismiss')),
 reason text not null check(length(btrim(reason))>0),
 review_after date not null,
 message_id bigint references memory.messages(id),
 created_at timestamptz not null default clock_timestamp()
);
create index review_decisions_subject on memory.review_decisions(kind,ref_id,id desc);
alter table memory.review_decisions enable row level security;
revoke all on memory.review_decisions from public,anon,authenticated;
grant select,insert on memory.review_decisions to service_role;
grant usage,select on sequence memory.review_decisions_id_seq to service_role;
create trigger review_decisions_immutable before update or delete on memory.review_decisions
 for each row execute function memory.protect_revision();
create trigger review_decisions_context after insert on memory.review_decisions
 for each statement execute function memory.invalidate_context();

create view memory.review_candidates with(security_invoker=true) as
with subjects as (
 select 'question'::text kind,q.id::text ref_id,md5(concat(q.text,q.ref_table,q.ref_id)) revision,
 q.text,q.score priority,q.created_at::date as day,q.ref_table,q.ref_id target_id
 from memory.questions q where q.closed_at is null
 and (q.deferred_until is null or q.deferred_until<=current_date)
 and not exists(select 1 from memory.plans p where q.ref_table='plans' and q.ref_id=p.id::text
   and (p.superseded_by is not null or p.status in ('done','skipped','dropped')))
 and not exists(select 1 from memory.reminders r where q.ref_table='reminders' and q.ref_id=r.id::text
   and r.status in ('done','cancelled'))
 union all
 select 'plan',p.id::text,p.version::text,p.item,2::real,p.day,'plans',p.id::text
 from memory.plans p where p.superseded_by is null and p.status in ('planned','partial','proposed')
 and p.day<current_date
 and not exists(select 1 from memory.questions q where q.ref_table='plans' and q.ref_id=p.id::text and q.closed_at is null)
)
select s.*,d.action,d.reason,d.review_after,d.created_at reviewed_at
from subjects s left join lateral (
 select * from memory.review_decisions d where d.kind=s.kind and d.ref_id=s.ref_id and d.revision=s.revision
 order by d.id desc limit 1
) d on true;
revoke all on memory.review_candidates from public,anon,authenticated;
grant select on memory.review_candidates to service_role;

alter table memory.routine_progress add column ended_at timestamptz,
 add column review_focus jsonb;

-- Deferred historical questions need not fill the visible plan panel. Outcomes stay intact.
create or replace function memory.plan_notes(p_day date) returns table (
 id bigint,day date,item text,status text,section text,version integer,outcome_note text
) language sql stable security invoker set search_path='' as $$
 select p.id,p.day,p.item,p.status,
 case when p.status in ('done','skipped','dropped') then 'finished'
      when p.day<p_day then 'review' when p.day>p_day then 'upcoming' else 'current' end,
 p.version,p.outcome_note
 from memory.plans p left join lateral (
 select d.* from memory.review_decisions d where d.kind='plan' and d.ref_id=p.id::text and d.revision=p.version::text
 order by d.id desc limit 1
 ) d on true
 where p.superseded_by is null and
 (p.status in ('planned','partial','proposed') and p.day<=p_day+7 or p.day=p_day)
 and (p.day>=p_day or d.action is null or d.action='keep' or d.action='defer' and d.review_after<=p_day)
 order by case when p.status in ('done','skipped','dropped') then 3
               when p.day=p_day then 0 when p.day<p_day then 1 else 2 end,p.day,p.id limit 100
$$;
