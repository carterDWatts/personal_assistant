alter table memory.reminders add column severity text not null default 'normal' check (severity in ('low','normal','high','critical'));
create table assistant.source_cursors (
 source text primary key,
 scanned_until timestamptz not null,
 checked_at timestamptz not null default now(),
 last_error text
);
create table assistant.source_items (
 source text not null,
 id text not null,
 payload jsonb,
 created_at timestamptz not null default now(),
 processed_at timestamptz,
 available_at timestamptz not null default now(),
 last_error text,
 message_id bigint references memory.messages(id),
 primary key(source,id)
);
create table assistant.attention (
 id uuid primary key default gen_random_uuid(),
 source text not null,
 source_id text not null,
 title text not null,
 detail text not null,
 notify boolean not null default false,
 created_at timestamptz not null default now(),
 unique(source,source_id)
);
create table assistant.attention_deliveries (
 notice_id uuid not null references assistant.attention(id) on delete cascade,
 device_id uuid not null references assistant.devices(id) on delete cascade,
 id uuid not null default gen_random_uuid(),
 sent_at timestamptz,
 cancelled_at timestamptz,
 retry_at timestamptz not null default now(),
 last_error text,
 primary key(notice_id,device_id)
);
create table assistant.maintenance_runs (
 day date primary key,
 completed_at timestamptz,
 available_at timestamptz not null default now(),
 last_error text,
 metrics jsonb
);
alter table assistant.source_cursors enable row level security;
alter table assistant.source_items enable row level security;
alter table assistant.attention enable row level security;
alter table assistant.attention_deliveries enable row level security;
alter table assistant.maintenance_runs enable row level security;
grant select,insert,update on assistant.source_cursors,assistant.source_items,assistant.attention,assistant.attention_deliveries,assistant.maintenance_runs to service_role;
create index source_items_pending on assistant.source_items(created_at) where processed_at is null;
create index attention_delivery_pending on assistant.attention_deliveries(retry_at) where sent_at is null;
create trigger context_changed after insert or update or delete on assistant.attention for each statement execute function memory.invalidate_context();

alter function assistant.day_snapshot() rename to day_snapshot_v2;
create function assistant.day_snapshot() returns jsonb language sql stable security invoker set search_path='' as $$
 select assistant.day_snapshot_v2() || jsonb_build_object(
 'attention',coalesce((select jsonb_agg(x order by x.created_at desc) from (select id,title,detail,source,source_id,created_at from assistant.attention order by created_at desc limit 10) x),'[]'::jsonb),
 'background',jsonb_build_object('mail_checked_at',(select checked_at from assistant.source_cursors where source='gmail'),'mail_error',(select last_error from assistant.source_cursors where source='gmail'),'nightly_completed_at',(select max(completed_at) from assistant.maintenance_runs)))
$$;
revoke all on function assistant.day_snapshot() from public;
grant execute on function assistant.day_snapshot() to service_role;
