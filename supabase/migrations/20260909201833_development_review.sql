create table assistant.development_review (
 singleton boolean primary key default true check(singleton),
 cursor bigint not null default 0,
 next_review_at timestamptz not null default now()
);
insert into assistant.development_review(singleton) values(true);
alter table assistant.development_review enable row level security;
revoke all on assistant.development_review from public,anon,authenticated;
grant select,update on assistant.development_review to service_role;
