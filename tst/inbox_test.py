import uuid
import psycopg
from engine.db import jsonb
from engine.outbound import post
from engine.conversation import Conversation
from tst.helpers import MapTest

class inbox_test(MapTest):
    def setUp(self):
        super().setUp()
        self.owner=uuid.uuid4();self.device=uuid.uuid4()
        self.map.execute('truncate assistant.owner cascade')
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.request('register',{'name':'test'})

    def request(self,action,args=None):
        return self.map.value('select public.assistant_client(%s,%s,%s,%s)',(self.owner,self.device,action,jsonb(args or {})))

    def test_inbox_only_enters_history_when_opened_and_retry_is_idempotent(self):
        original=post(self.map,'example','Your report is ready.',{'kind':'notice','id':str(uuid.uuid4())})
        self.assertEqual(len(self.request('inbox')['messages']),1)
        self.assertEqual(self.request('bootstrap')['history'],[])
        request={'request_id':str(uuid.uuid4()),'message_id':str(original)}
        opened=self.request('inbox_open',request)['message']
        self.assertNotEqual(opened['id'],original)
        self.assertEqual(self.request('inbox_open',request)['message']['id'],opened['id'])
        self.assertEqual(self.request('inbox_open',{**request,'request_id':str(uuid.uuid4())})['message']['id'],opened['id'])
        self.assertEqual([m['id'] for m in self.request('bootstrap')['history']],[opened['id']])
        self.assertIsNotNone(self.request('inbox')['messages'][0]['opened_at'])
        conv=Conversation(self.map,'test','codex')
        self.assertEqual([m['id'] for m in conv.tail(100)],[opened['id']])
        other=post(self.map,'other','Second message.')
        with self.assertRaisesRegex(psycopg.Error,'idempotency_conflict'):
            self.request('inbox_open',{**request,'message_id':str(other)})

    def test_reading_and_clearing_chat_does_not_acknowledge_or_lose_inbox(self):
        original=post(self.map,'example','Remember the report.')
        self.request('clear',{'request_id':str(uuid.uuid4())})
        self.assertEqual(self.request('bootstrap')['history'],[])
        self.assertIsNone(self.request('inbox')['messages'][0]['opened_at'])
        with self.assertRaisesRegex(psycopg.Error,'device_denied'):
            self.map.value('select public.assistant_client(%s,%s,%s,%s)',(self.owner,uuid.uuid4(),'inbox',jsonb({})))
        self.request('inbox_open',{'request_id':str(uuid.uuid4()),'message_id':str(original)})
        self.assertEqual(len(self.request('bootstrap')['history']),1)
