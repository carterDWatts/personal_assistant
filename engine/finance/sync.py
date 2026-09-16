"""Incremental bank ingestion. A failed page never advances the saved cursor."""
import asyncio
import base64
import os
from decimal import Decimal

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from engine.db import Map, jsonb
from engine.finance.plaid import Plaid, PlaidError


def decrypt(item):
    key = os.environ.get('ASSISTANT_CREDENTIAL_KEY')
    if not key:
        import keyring
        key = keyring.get_password('com.carterwatts.personal-assistant.plaid', 'cipher-key')
    raw = base64.b64decode(item['ciphertext'])
    aad = f"{item['user_id']}:plaid:{item['environment']}:{item['id']}".encode()
    return AESGCM(base64.b64decode(key)).decrypt(raw[:12], raw[12:], aad).decode()


def exact(value):
    if isinstance(value, Decimal): return str(value)
    if isinstance(value, dict): return {k:exact(v) for k,v in value.items()}
    if isinstance(value, list): return [exact(v) for v in value]
    return value


def read_changes(api, token, cursor):
    # Plaid can mutate a result set between pages. Restart the *entire* traversal.
    for retry in range(3):
        pages=[]; next_cursor=cursor
        try:
            for _ in range(100):
                page=api.call('/transactions/sync',access_token=token,cursor=next_cursor,count=500)
                pages.append(page); next_cursor=page['next_cursor']
                if not page['has_more']: return pages,next_cursor
            raise PlaidError('SYNC_TOO_LARGE')
        except PlaidError as error:
            if error.code!='TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION' or retry==2: raise
    raise AssertionError('Unreachable')


def apply(map_, item, accounts, pages, cursor, liabilities, bank_updated_at):
    with map_.conn.transaction():
        current=map_.row('select active,ciphertext,cursor from assistant.bank_items where user_id=%s and id=%s for update', (item['user_id'],item['id']))
        if not current or not current['active'] or current['ciphertext']!=item['ciphertext'] or current['cursor']!=item['cursor']:
            return False  # Disconnect, reconnect or another sync won the race.
        map_.execute("update assistant.bank_accounts set active=false where user_id=%s and item_id=%s",(item['user_id'],item['id']))
        for account in accounts:
            balances=account['balances']
            map_.execute('''insert into assistant.bank_accounts(user_id,item_id,id,name,mask,type,subtype,currency,balance,available,credit_limit,liabilities)
              values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) on conflict(user_id,item_id,id) do update set
              active=true,name=excluded.name,mask=excluded.mask,type=excluded.type,subtype=excluded.subtype,currency=excluded.currency,
              balance=excluded.balance,available=excluded.available,credit_limit=excluded.credit_limit,liabilities=excluded.liabilities''',
              (item['user_id'],item['id'],account['account_id'],account['name'],account.get('mask'),account['type'],account.get('subtype'),
               balances.get('iso_currency_code') or balances.get('unofficial_currency_code'),balances.get('current'),balances.get('available'),balances.get('limit'),jsonb(exact(liabilities.get(account['account_id'],{})))))
        for page in pages:
            for txn in page['added']+page['modified']:
                map_.execute('''insert into assistant.bank_transactions(user_id,item_id,id,account_id,day,name,merchant,amount,currency,pending,pending_id,category)
                  values(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) on conflict(user_id,item_id,id) do update set
                  account_id=excluded.account_id,day=excluded.day,name=excluded.name,merchant=excluded.merchant,amount=excluded.amount,
                  currency=excluded.currency,pending=excluded.pending,pending_id=excluded.pending_id,category=excluded.category,removed=false''',
                  (item['user_id'],item['id'],txn['transaction_id'],txn['account_id'],txn['date'],txn['name'],txn.get('merchant_name'),
                   txn['amount'],txn.get('iso_currency_code') or txn.get('unofficial_currency_code'),txn['pending'],txn.get('pending_transaction_id'),
                   (txn.get('personal_finance_category') or {}).get('primary')))
                if txn.get('pending_transaction_id'):
                    map_.execute('update assistant.bank_transactions set removed=true where user_id=%s and item_id=%s and id=%s',
                                 (item['user_id'],item['id'],txn['pending_transaction_id']))
            for txn in page['removed']:
                map_.execute('update assistant.bank_transactions set removed=true where user_id=%s and item_id=%s and id=%s',
                             (item['user_id'],item['id'],txn['transaction_id']))
        map_.execute("""update assistant.bank_transactions pending set removed=true where pending.user_id=%s and pending.item_id=%s
          and pending.pending and exists(select 1 from assistant.bank_transactions posted where posted.user_id=pending.user_id
          and posted.item_id=pending.item_id and posted.pending_id=pending.id and not posted.pending and not posted.removed)""",(item['user_id'],item['id']))
        update_status=pages[-1].get('transactions_update_status','TRANSACTIONS_UPDATE_STATUS_UNKNOWN') if pages else 'TRANSACTIONS_UPDATE_STATUS_UNKNOWN'
        delay='1 minute' if update_status in ('NOT_READY','INITIAL_UPDATE_COMPLETE') else '4 hours'
        map_.execute("update assistant.bank_items set transactions_status=%s,next_sync_at=now()+%s::interval,cursor=%s,synced_at=now(),bank_updated_at=%s,last_error=null where user_id=%s and id=%s",
                     (update_status,delay,cursor,bank_updated_at,item['user_id'],item['id']))
    return True


def sync_item(map_, item, api):
    if api.environment!=item['environment']: raise PlaidError('ENVIRONMENT_MISMATCH')
    token=decrypt(item)
    if not item['active']:
        try: api.call('/item/remove',access_token=token)
        except PlaidError as error:
            if error.code!='ITEM_NOT_FOUND': raise
        map_.execute('delete from assistant.bank_items where user_id=%s and id=%s and not active and ciphertext=%s',
                     (item['user_id'],item['id'],item['ciphertext']))
        return
    accounts=api.call('/accounts/get',access_token=token)['accounts']
    pages,cursor=read_changes(api,token,item['cursor'])
    metadata=api.call('/item/get',access_token=token)
    liabilities={}
    if 'liabilities' in metadata['item'].get('products',metadata['item'].get('billed_products',[])):
        data=api.call('/liabilities/get',access_token=token)
        for rows in data.get('liabilities',{}).values():
            for row in rows or []:
                liabilities[row['account_id']]={key:row[key] for key in ('next_payment_due_date','minimum_payment_amount','last_payment_amount','last_payment_date','last_statement_balance','last_statement_issue_date','is_overdue','aprs','interest_rate') if key in row}
    stamp=((metadata.get('status') or {}).get('transactions') or {}).get('last_successful_update')
    apply(map_,item,accounts,pages,cursor,liabilities,stamp)


def poll(map_, api=None):
    # Independent of model turns. No model invocation or account-wide context injection.
    if not map_.value("select pg_try_advisory_lock(hashtextextended('bank-sync',0))"): return
    try:
        rows=map_.rows('select * from assistant.bank_items where next_sync_at<=now() order by next_sync_at limit 10')
        if not rows:return
        api=api or Plaid()
        for item in rows:
            try: sync_item(map_,item,api)
            except Exception as error:
                code=error.code if isinstance(error,PlaidError) else 'SYNC_UNAVAILABLE'
                map_.execute("update assistant.bank_items set last_error=%s,next_sync_at=now()+interval '15 minutes' where user_id=%s and id=%s and ciphertext=%s",
                             (code,item['user_id'],item['id'],item['ciphertext']))
    finally: map_.execute("select pg_advisory_unlock(hashtextextended('bank-sync',0))")


async def run(url,host):
    await host.ready.wait()
    map_=Map(url)
    try:
        while not host.stopping.is_set():
            try: await asyncio.to_thread(poll,map_)
            except Exception: print('Bank sync deferred.',flush=True)
            try: await asyncio.wait_for(host.stopping.wait(),30)
            except asyncio.TimeoutError: pass
    finally: map_.close()
