import os
import base64
import uuid
from unittest.mock import patch

import psycopg
from engine import credentials
from engine.db import jsonb
from tst.helpers import MapTest


class cloud_connections_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner cascade')
        self.owner, self.device = uuid.uuid4(), uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)', (self.owner,))
        self.map.value('select public.assistant_client(%s,%s,\'register\',\'{"name":"Test"}\')', (self.owner,self.device))

    def tearDown(self):
        self.map.execute('truncate assistant.owner cascade')
        super().tearDown()

    def store(self, action, args=None, device=None):
        return self.map.value('select public.assistant_connection_store(%s,%s,%s,%s)',
                              (self.owner,device or self.device,action,jsonb(args or {})))

    def test_intents_are_owned_single_use_and_disconnect_cancels_them(self):
        intent = self.store('begin', {'slot':'google_connect','state_hash':'state','verifier':'encrypted'})
        with self.assertRaises(psycopg.Error): self.store('status', intent, uuid.uuid4())
        claimed = self.store('claim', {'state_hash':'state'})
        self.assertEqual(claimed['verifier'], 'encrypted')
        with self.assertRaises(psycopg.Error): self.store('claim', {'state_hash':'state'})
        self.store('remove', {'slot':'google_connect'})
        with self.assertRaises(psycopg.Error):
            self.store('complete', {**intent,'ciphertext':'secret','metadata':{}})
        self.assertEqual(self.store('list'), [])

    def test_expired_and_revoked_intents_fail(self):
        self.store('begin', {'slot':'google_connect','state_hash':'expired','verifier':'encrypted'})
        self.map.execute("update assistant.connection_intents set expires_at=now()-interval '1 second'")
        with self.assertRaises(psycopg.Error): self.store('claim', {'state_hash':'expired'})
        self.map.execute('update assistant.devices set revoked_at=now()')
        with self.assertRaises(psycopg.Error): self.store('save', {'slot':'github','ciphertext':'secret','metadata':{}})

    def test_encryption_and_refresh_do_not_restore_old_credentials(self):
        key = base64.b64encode(os.urandom(32)).decode()
        with patch.dict(os.environ, ASSISTANT_CREDENTIAL_KEY=key), patch('engine.config.ENV','prod'), patch('engine.db.Map', return_value=self.map), patch.object(self.map,'close'):
            nonce = os.urandom(12)
            aad = f'{self.owner}:google_connect'.encode()
            encrypted = base64.b64encode(nonce+credentials._cipher().encrypt(nonce,b'original',aad)).decode()
            self.store('save', {'slot':'google_connect','ciphertext':encrypted,'metadata':{'account':'test'}})
            service = 'com.carterwatts.personal-assistant.google'
            self.assertEqual(credentials.get_password(service,'prod'),'original')
            self.store('save', {'slot':'google_connect','ciphertext':'reconnected','metadata':{}})
            credentials.set_password(service,'prod','stale refresh')
            self.assertEqual(self.map.value('select ciphertext from assistant.credentials'),'reconnected')
            self.assertNotIn('ciphertext', self.store('list')[0])

    def waiting_request(self, action='notion_connect', slot='notion', scopes=None):
        turn=self.map.value("insert into assistant.turns(user_id,device_id,client_message_id,text,status) values(%s,%s,%s,'Read the project page','completed') returning id",(self.owner,self.device,uuid.uuid4()))
        self.map.execute('select assistant.emit(%s,%s,%s)',(self.owner,turn,jsonb({'type':'connection_required','action':action,'slot':slot,'scopes':scopes or []})))
        return turn

    def test_verified_connection_resumes_waiting_step_once_without_user_message(self):
        turn=self.waiting_request()
        intent=self.store('begin',{'slot':'notion','state_hash':'resume','verifier':'sealed'})
        self.store('claim',{'state_hash':'resume'})
        self.store('complete',{**intent,'ciphertext':'sealed','metadata':{'account':'test'}})
        self.map.execute('select assistant.resume_connection()')
        self.map.execute('select assistant.resume_connection()')
        resumed=self.map.row("select * from assistant.turns where status='queued'")
        self.assertEqual(resumed['invocation'],'connection')
        self.assertEqual(self.map.value('select resumed_turn from assistant.connection_waits where turn_id=%s',(turn,)),resumed['id'])
        self.assertEqual(self.map.value('select count(*) from assistant.turns'),2)
        self.assertEqual(self.map.value("select count(*) from memory.messages where role='user'"),0)

    def test_wrong_grant_and_changed_request_do_not_resume(self):
        self.waiting_request('google_calendar_write','google_connect',['calendar.write'])
        self.store('save',{'slot':'google_connect','ciphertext':'sealed','metadata':{'scopes':['calendar.read']}})
        self.map.execute('select assistant.resume_connection()')
        self.assertFalse(self.map.value('select ready from assistant.connection_waits'))
        self.store('save',{'slot':'google_connect','ciphertext':'sealed','metadata':{'scopes':['calendar.read','calendar.write']}})
        self.map.execute("insert into assistant.turns(user_id,device_id,client_message_id,text,status) values(%s,%s,%s,'Do something else','completed')",(self.owner,self.device,uuid.uuid4()))
        self.map.execute('select assistant.resume_connection()')
        self.assertEqual(self.map.value("select count(*) from assistant.turns where invocation='connection'"),0)

    def test_failed_or_cancelled_setup_cannot_resume(self):
        turn=self.waiting_request()
        intent=self.store('begin',{'slot':'notion','state_hash':'cancel','verifier':'sealed'})
        self.store('fail',intent)
        self.map.execute('select assistant.resume_connection()')
        self.assertFalse(self.map.value('select ready from assistant.connection_waits'))
        self.map.execute("update assistant.turns set status='cancelled' where id=%s",(turn,))
        self.store('save',{'slot':'notion','ciphertext':'sealed','metadata':{}})
        self.map.execute('select assistant.resume_connection()')
        self.assertEqual(self.map.value('select count(*) from assistant.turns'),1)
