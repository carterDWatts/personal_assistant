import uuid
from decimal import Decimal
from unittest import TestCase
from unittest.mock import Mock, patch

import psycopg

from engine.db import jsonb
from engine.finance.sync import apply, read_changes, poll, sync_item
from engine.finance.plaid import PlaidError, Plaid
from engine.finance.tools import read
from tst.helpers import MapTest


def account():
    return {'account_id':'checking','name':'Checking','type':'depository','balances':{'current':Decimal('200.10'),'iso_currency_code':'USD'}}


def transaction(id='pending', amount='12.34', pending=True, **changes):
    return dict({'transaction_id':id,'account_id':'checking','date':'2026-09-16','name':'Lunch','amount':Decimal(amount),
                 'iso_currency_code':'USD','pending':pending,'personal_finance_category':{'primary':'FOOD_AND_DRINK'}},**changes)


def page(added=None, modified=None, removed=None, cursor='next', more=False):
    return {'added':added or [],'modified':modified or [],'removed':removed or [],'next_cursor':cursor,'has_more':more}


class BankPages(TestCase):
    def test_mutation_restarts_from_original_cursor(self):
        api=Mock()
        api.call.side_effect=[page([transaction('discard')],cursor='partial',more=True),
                              PlaidError('TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION'),page([transaction('keep')])]
        pages,cursor=read_changes(api,'private','original')
        self.assertEqual([call.kwargs['cursor'] for call in api.call.call_args_list],['original','partial','original'])
        self.assertEqual([row['transaction_id'] for row in pages[0]['added']],['keep'])

    def test_partial_error_returns_no_changes(self):
        api=Mock();api.call.side_effect=[page(more=True),PlaidError('UNAVAILABLE')]
        with self.assertRaises(PlaidError):read_changes(api,'private','original')

    def test_adapter_cannot_transfer_money(self):
        with self.assertRaises(ValueError):Plaid({'environment':'sandbox'}).call('/transfer/create')


class BankLedger(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner cascade')
        self.owner=uuid.uuid4();self.device=uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.map.value("select public.assistant_client(%s,%s,'register','{\"name\":\"Test\"}')",(self.owner,self.device))
        self.map.execute("insert into assistant.bank_items(user_id,id,environment,ciphertext,institution) values(%s,'item','sandbox','private','Test bank')",(self.owner,))
        self.item=self.current()

    def tearDown(self):
        self.map.execute('truncate assistant.owner cascade')
        super().tearDown()

    def current(self):return self.map.row("select * from assistant.bank_items where id='item'")

    def commit(self, *pages):return apply(self.map,self.current(),[account()],list(pages),'cursor',{},None)

    def test_pending_posting_modification_and_removal_are_idempotent(self):
        self.commit(page([transaction()]))
        posted=transaction('posted',pending=False,pending_transaction_id='pending')
        self.commit(page([posted]))
        self.commit(page([posted]))
        self.assertEqual(self.map.value('select sum(amount) from assistant.bank_transactions where not removed'),Decimal('12.34'))
        self.commit(page(modified=[transaction('posted','14.00',False)]))
        self.assertEqual(self.map.value('select sum(amount) from assistant.bank_transactions where not removed'),Decimal('14.00'))
        self.commit(page(removed=[{'transaction_id':'posted'}]))
        self.assertEqual(self.map.value('select count(*) from assistant.bank_transactions where not removed'),0)

    def test_failed_commit_rolls_back_accounts_transactions_and_cursor(self):
        broken=transaction('bad',account_id='unknown')
        with self.assertRaises(psycopg.Error):self.commit(page([transaction(),broken]))
        self.assertEqual(self.current()['cursor'],'')
        self.assertEqual(self.map.value('select count(*) from assistant.bank_accounts'),0)
        self.assertEqual(self.map.value('select count(*) from assistant.bank_transactions'),0)

    def test_disconnect_or_changed_credentials_prevents_stale_sync(self):
        self.map.execute('update assistant.bank_items set active=false')
        self.assertFalse(apply(self.map,self.item,[account()],[page([transaction()])],'stale',{},None))
        self.map.execute("update assistant.bank_items set active=true,ciphertext='new'")
        self.assertFalse(apply(self.map,self.item,[account()],[],'stale',{},None))
        self.assertEqual(self.current()['cursor'],'')

    def test_exact_totals_keep_refunds_transfers_pending_and_currencies_distinct(self):
        self.commit(page([transaction('charge','0.10',False),transaction('refund','-0.03',False),transaction('pending','7',True),
                          transaction('cad','5',False,iso_currency_code='CAD'),
                          transaction('card-payment','100',False,personal_finance_category={'primary':'LOAN_PAYMENTS'})]))
        with patch('engine.finance.tools.Map',return_value=self.map),patch.object(self.map,'close'):
            result=read({'start':'2026-09-01','end':'2026-09-30'},'summary')
        food=next(row for row in result['groups'] if row['currency']=='USD' and row['category']=='FOOD_AND_DRINK' and not row['pending'])
        self.assertEqual(food['net_outflow'],'0.07')
        self.assertEqual(len(result['groups']),4)
        self.assertNotIn('ciphertext',str(result));self.assertNotIn('private',str(result))
        self.assertIn('bank_updated_at',result['connections'][0])
        self.assertIn('Deterministic',result['note'])
        self.assertEqual(result['coverage'],'partial_history')
        self.assertEqual(result['freshness'],'cached')

    def test_revocation_is_retried_and_data_not_readable_while_waiting(self):
        self.map.value("select public.assistant_bank_store(%s,%s,'remove','{}')",(self.owner,self.device))
        api=Mock(environment='sandbox');api.call.side_effect=PlaidError('UNAVAILABLE')
        with patch('engine.finance.sync.decrypt',return_value='token'):poll(self.map,api)
        self.assertFalse(self.current()['active']);self.assertEqual(self.current()['last_error'],'UNAVAILABLE')
        api.call.side_effect=None
        with patch('engine.finance.sync.decrypt',return_value='token'):sync_item(self.map,self.current(),api)
        self.assertIsNone(self.current())

    def test_bank_commit_requires_owned_unexpired_claimed_intent(self):
        def store(action,args):
            return self.map.value('select public.assistant_connection_store(%s,%s,%s,%s)',(self.owner,self.device,action,jsonb(args)))
        intent=store('begin',{'slot':'plaid','state_hash':'state','verifier':'private'})
        args={**intent,'item_id':'second','environment':'sandbox','ciphertext':'encrypted','institution':'Other bank'}
        with self.assertRaises(psycopg.Error):
            self.map.value("select public.assistant_bank_store(%s,%s,'complete',%s)",(self.owner,self.device,jsonb(args)))
        store('claim',{'state_hash':'state'})
        with self.assertRaises(psycopg.Error):
            self.map.value("select public.assistant_bank_store(%s,%s,'complete',%s)",(self.owner,uuid.uuid4(),jsonb(args)))
        self.map.value("select public.assistant_bank_store(%s,%s,'complete',%s)",(self.owner,self.device,jsonb(args)))
        self.assertEqual(store('status',intent)['state'],'connected')
        self.assertEqual(self.map.value('select count(*) from assistant.bank_items'),2)

    def test_view_has_only_public_fields_and_hides_disconnected_data(self):
        self.commit(page([transaction()]))
        def view(owner):return self.map.value("select public.assistant_bank_store(%s,%s,'view','{}')",(owner,self.device))
        result=view(self.owner)
        self.assertEqual(result['accounts'][0]['balance'],'200.10')
        self.assertNotIn('ciphertext',str(result));self.assertNotIn('private',str(result))
        with self.assertRaises(psycopg.Error):view(uuid.uuid4())
        self.map.execute('update assistant.bank_items set active=false')
        self.assertEqual(view(self.owner),{'accounts':[],'connections':[]})

    def test_anonymous_clients_cannot_read_or_commit(self):
        with self.map.conn.transaction():
            self.map.execute('set local role anon')
            with self.assertRaises(psycopg.Error),self.map.conn.transaction():self.map.rows('select * from assistant.bank_items')
            with self.assertRaises(psycopg.Error),self.map.conn.transaction():self.map.value("select public.assistant_bank_store(%s,%s,'remove','{}')",(self.owner,self.device))


class BankSandbox(BankLedger):
    def setUp(self):
        import os
        if not os.environ.get('BANK_SANDBOX_CONFIG'): self.skipTest('Opt-in Plaid Sandbox test')
        super().setUp()

    def test_real_sandbox_pipeline(self):
        import base64,json,os,time
        from pathlib import Path
        import requests
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        settings=json.loads(Path(os.environ['BANK_SANDBOX_CONFIG']).read_text())
        self.assertEqual(settings['environment'],'sandbox')
        auth={k:settings[k] for k in ('client_id','secret')}
        def api(path,**args):
            result=requests.post('https://sandbox.plaid.com'+path,json={**auth,**args},timeout=30)
            if not result.ok:raise AssertionError('Sandbox request failed: '+result.json().get('error_code','UNKNOWN'))
            return result.json()
        token=None
        try:
            public=api('/sandbox/public_token/create',institution_id='ins_109508',initial_products=['transactions','liabilities'])
            token=api('/item/public_token/exchange',public_token=public['public_token'])['access_token']
            key=os.urandom(32);nonce=os.urandom(12)
            ciphertext=base64.b64encode(nonce+AESGCM(key).encrypt(nonce,token.encode(),f'{self.owner}:plaid:sandbox:item'.encode())).decode()
            self.map.execute('update assistant.bank_items set ciphertext=%s',(ciphertext,))
            adapter=Plaid(settings)
            with patch.dict(os.environ,ASSISTANT_CREDENTIAL_KEY=base64.b64encode(key).decode()):
                for _ in range(15):
                    sync_item(self.map,self.current(),adapter)
                    if self.current()['transactions_status']=='HISTORICAL_UPDATE_COMPLETE':break
                    time.sleep(2)
            self.assertGreater(self.map.value('select count(*) from assistant.bank_accounts'),0)
            self.assertGreater(self.map.value('select count(*) from assistant.bank_transactions'),0)
            self.assertEqual(self.current()['transactions_status'],'HISTORICAL_UPDATE_COMPLETE')
            self.assertGreater(self.map.value("select count(*) from assistant.bank_accounts where liabilities<>'{}'"),0)
            with patch('engine.finance.tools.Map',return_value=self.map),patch.object(self.map,'close'):
                result=read({},'accounts')
            self.assertNotIn(token,str(result));self.assertNotIn(settings['secret'],str(result))
        finally:
            if token: api('/item/remove',access_token=token)
