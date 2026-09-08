import base64
from datetime import datetime, timezone
from unittest.mock import patch
from engine.background import Background, poll_mail
from engine.db import jsonb
from engine.notifications import Dispatcher
from tst.helpers import MapTest, FakeRuntime, call

class background_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.source_cursors,assistant.source_items,assistant.attention,assistant.maintenance_runs cascade')

    def test_poll_saves_all_pages_and_deduplicates_without_inference(self):
        with patch('engine.integrations.google._get',side_effect=[{'messages':[{'id':'a'}],'nextPageToken':'next'},{'messages':[{'id':'b'}]}]) as get:
            poll_mail(self.map)
            self.assertEqual(get.call_count,2)
        self.assertEqual(self.map.value('select count(*) from assistant.source_items'),2)
        with patch('engine.integrations.google._get') as get:
            poll_mail(self.map)
            get.assert_not_called()

    def test_failed_page_never_advances_cursor(self):
        with patch('engine.integrations.google._get',side_effect=[{'messages':[{'id':'a'}],'nextPageToken':'next'},TimeoutError]):
            with self.assertRaises(TimeoutError): poll_mail(self.map)
        self.assertEqual(self.map.value('select count(*) from assistant.source_cursors'),0)
        self.assertEqual(self.map.value('select count(*) from assistant.source_items'),1)
        with patch('engine.integrations.google._get',return_value={'messages':[{'id':'a'}]}): poll_mail(self.map)
        self.assertEqual(self.map.value('select count(*) from assistant.source_items'),1)

    def test_sent_mail_updates_context_without_notifying(self):
        self.map.execute("insert into assistant.source_items(source,id) values('gmail','abc')")
        classification={'items':[{'id':'abc','relevant':True,'notify':True,'remember':True,'title':'Application sent','reason':'The user submitted an application.'}]}
        runtime=FakeRuntime([[call('classify',**classification)]])
        raw={'id':'abc','internalDate':'1788840000000','labelIds':['SENT','UNREAD'], 'payload':{'mimeType':'text/plain','body':{'data':base64.urlsafe_b64encode(b'Application submitted').decode()}}}
        with patch('engine.integrations.google._get',return_value=raw): self.run_async(Background(self.map,lambda _:runtime).triage())
        self.assertIn('Facts (current',runtime.sent[0])
        self.assertFalse(self.map.value('select notify from assistant.attention'))
        self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'),1)
        self.assertTrue(self.map.value("select (payload->>'external')::boolean from memory.messages"))
        self.assertEqual(self.map.value('select role from memory.messages'),'system')

    def test_failed_classification_backs_off(self):
        self.map.execute("insert into assistant.source_items(source,id) values('gmail','abc')")
        with patch('engine.integrations.google._get',side_effect=TimeoutError): self.run_async(Background(self.map).triage())
        self.assertTrue(self.map.value('select available_at>now() from assistant.source_items'))
        self.assertIsNone(self.map.value('select processed_at from assistant.source_items'))

    def test_nightly_requires_committed_organization(self):
        class Clock(datetime):
            @classmethod
            def now(cls,tz=None): return datetime(2026,9,9,4,tzinfo=tz or timezone.utc)
        with patch('engine.background.datetime',Clock):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[]])).nightly())
        self.assertIsNone(self.map.value('select completed_at from assistant.maintenance_runs'))
        self.assertIsNotNone(self.map.value('select last_error from assistant.maintenance_runs'))
        self.map.execute("update assistant.maintenance_runs set available_at='2020-01-01'")
        with patch('engine.background.datetime',Clock):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[call('organize',questions=[])]])).nightly())
        self.assertIsNotNone(self.map.value('select completed_at from assistant.maintenance_runs'))

    def test_initial_mail_sync_does_not_notify(self):
        self.map.execute("insert into assistant.source_items(source,id,payload) values('gmail','initial','{\"backfill\":true}')")
        classified={'items':[{'id':'initial','relevant':True,'notify':True,'remember':False,'title':'Past mail','reason':'An older item.'}]}
        raw={'id':'initial','internalDate':'1788840000000','labelIds':['UNREAD'],'payload':{}}
        with patch('engine.integrations.google._get',return_value=raw):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[call('classify',**classified)]])).triage())
        self.assertFalse(self.map.value('select notify from assistant.attention'))
        self.assertFalse(self.map.value("select payload ? 'body' from assistant.source_items"))

    def test_same_email_thread_is_not_notified_twice_per_day(self):
        self.map.execute("insert into assistant.source_items(source,id) values('gmail','one'),('gmail','two')")
        items=[{'id':id,'relevant':True,'notify':True,'remember':False,'title':id,'reason':'A reply.'} for id in ('one','two')]
        raw={'threadId':'same-thread','internalDate':'1788840000000','labelIds':['UNREAD'],'payload':{}}
        with patch('engine.integrations.google._get',return_value=raw):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[call('classify',items=items)]])).triage())
        self.assertEqual(self.map.value('select count(*) from assistant.attention'),1)
