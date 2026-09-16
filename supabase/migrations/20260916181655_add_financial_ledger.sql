-- Financial source records stay out of the semantic memory graph.
create table assistant.bank_items (
 user_id uuid not null references assistant.owner(user_id),
 id text not null,
 environment text not null check(environment in ('sandbox','production')),
 ciphertext text not null,
 institution text not null,
 active boolean not null default true,
 cursor text not null default '',
 synced_at timestamptz,
 bank_updated_at timestamptz,
 transactions_status text not null default 'NOT_READY',
 next_sync_at timestamptz not null default now(),
 last_error text,
 primary key(user_id,id)
);
create index bank_items_due on assistant.bank_items(next_sync_at);
create table assistant.bank_accounts (
 user_id uuid not null,
 item_id text not null,
 id text not null,
 name text not null,
 active boolean not null default true,
 mask text,
 type text not null,
 subtype text,
 currency text,
 balance numeric,
 available numeric,
 credit_limit numeric,
 liabilities jsonb not null default '{}',
 primary key(user_id,item_id,id),
 foreign key(user_id,item_id) references assistant.bank_items(user_id,id) on delete cascade
);
create table assistant.bank_transactions (
 user_id uuid not null,
 item_id text not null,
 id text not null,
 account_id text not null,
 day date not null,
 name text not null,
 merchant text,
 amount numeric not null,
 currency text,
 pending boolean not null,
 pending_id text,
 category text,
 removed boolean not null default false,
 primary key(user_id,item_id,id),
 foreign key(user_id,item_id,account_id) references assistant.bank_accounts(user_id,item_id,id) on delete cascade
);
create index bank_transactions_by_date on assistant.bank_transactions(user_id,day desc,id) where not removed;
alter table assistant.bank_items enable row level security;
alter table assistant.bank_accounts enable row level security;
alter table assistant.bank_transactions enable row level security;
revoke all on assistant.bank_items,assistant.bank_accounts,assistant.bank_transactions from public,anon,authenticated;
grant select,insert,update,delete on assistant.bank_items,assistant.bank_accounts,assistant.bank_transactions to service_role;

alter table assistant.credentials drop constraint credentials_slot_check;
alter table assistant.credentials add constraint credentials_slot_check check(slot in
 ('google_connect','google_tasks','google_drive','google_contacts','google_mail_send','todoist','notion','github','supabase','spotify','plaid'));

-- Gateway-only commit joins bank ownership, the connection marker and request resumption.
create function public.assistant_bank_store(p_user uuid,p_device uuid,p_action text,p_args jsonb default '{}') returns jsonb
language plpgsql security invoker set search_path='' as $$
declare intent assistant.connection_intents; result jsonb;
begin
 perform 1 from assistant.owner where user_id=p_user for update;
 if not found then raise exception 'account_denied' using errcode='42501'; end if;
 perform assistant.require_device(p_user,p_device);
 case p_action
 when 'repair' then
  select to_jsonb(b) into result from assistant.bank_items b where user_id=p_user and active
   and last_error in ('ITEM_LOGIN_REQUIRED','ITEM_LOCKED','PENDING_EXPIRATION') order by id limit 1;
 when 'view' then
  result:=jsonb_build_object('connections',coalesce((select jsonb_agg(jsonb_build_object('id',id,'institution',institution,
   'synced_at',synced_at,'bank_updated_at',bank_updated_at,'transactions_status',transactions_status,'last_error',last_error))
   from assistant.bank_items where user_id=p_user and active),'[]'),
   'accounts',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'item_id',a.item_id,'name',a.name,'mask',a.mask,'active',a.active,
    'type',a.type,'currency',a.currency,'balance',a.balance::text,'available',a.available::text,'liabilities',a.liabilities))
    from assistant.bank_accounts a join assistant.bank_items b on b.user_id=a.user_id and b.id=a.item_id where a.user_id=p_user and b.active),'[]'));
 when 'complete' then
  select * into intent from assistant.connection_intents where id=(p_args->>'intent_id')::uuid
   and user_id=p_user and device_id=p_device and slot='plaid' for update;
  if not found or intent.state<>'processing' or intent.expires_at<=now() then raise exception 'invalid_request'; end if;
  insert into assistant.bank_items(user_id,id,environment,ciphertext,institution)
   values(p_user,p_args->>'item_id',p_args->>'environment',p_args->>'ciphertext',left(p_args->>'institution',200))
   on conflict(user_id,id) do update set ciphertext=excluded.ciphertext,active=true,last_error=null,next_sync_at=now();
  result:=public.assistant_connection_store(p_user,p_device,'complete',jsonb_build_object(
   'intent_id',intent.id,'ciphertext','bank-tokens-stored-separately','metadata',jsonb_build_object('account','Bank accounts','kind','bank_link')));
 when 'remove' then
  update assistant.bank_items set active=false,next_sync_at=now() where user_id=p_user;
  result:=public.assistant_connection_store(p_user,p_device,'remove','{"slot":"plaid"}');
 else raise exception 'invalid_request';
 end case;
 return result;
end $$;
revoke all on function public.assistant_bank_store(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.assistant_bank_store(uuid,uuid,text,jsonb) to service_role;
