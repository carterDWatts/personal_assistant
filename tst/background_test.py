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

    def test_emergent_review_deduplicates_and_skips_unchanged_map(self):
        from engine.attention import review
        from engine.tools import Tools
        tools=Tools(self.map,'test')
        entity=self.run_async(tools.entity_upsert({'type':'project','name':'An active project'}))['id']
        self.run_async(tools.attribute_register({'name':'deadline','value_type':'text','cardinality':'single'}))
        fact=self.run_async(tools.fact_assert({'entity_id':str(entity),'attribute':'deadline','value':'Tomorrow'}))
        alert={'category':'deadline','title':'A deadline needs attention','reason':'A current commitment is approaching.','evidence':[{'kind':'assertions','id':str(fact['id'])}]}
        runtime=FakeRuntime([[call('review_attention',alerts=[alert])]])
        self.run_async(review(self.map,lambda _:runtime))
        self.assertEqual(self.map.value("select count(*) from assistant.attention where source='context'"),1)
        self.run_async(review(self.map,lambda _:self.fail('Unchanged memory must not invoke a model')))
        self.map.execute("update assistant.source_items set available_at='2020-01-01',payload=null where source='context-review'")
        self.run_async(review(self.map,lambda _:FakeRuntime([[call('review_attention',alerts=[alert])]])))
        self.assertEqual(self.map.value("select count(*) from assistant.attention where source='context'"),1)

    def test_emergent_review_rejects_missing_evidence(self):
        from engine.attention import review
        alert={'category':'risk','title':'An unsupported claim','reason':'No evidence.','evidence':[{'kind':'assertions','id':'00000000-0000-0000-0000-000000000000'}]}
        self.run_async(review(self.map,lambda _:FakeRuntime([[call('review_attention',alerts=[alert])]])))
        self.assertEqual(self.map.value("select count(*) from assistant.attention where source='context'"),0)
        self.assertIsNotNone(self.map.value("select last_error from assistant.source_items where source='context-review'"))

    def test_failure_does_not_delay_unattempted_mail(self):
        for index in range(7):
            self.map.execute("insert into assistant.source_items(source,id) values('gmail',%s)",(str(index),))
        with patch('engine.integrations.google._get',side_effect=TimeoutError):
            self.run_async(Background(self.map).triage())
        self.assertEqual(self.map.value("select count(*) from assistant.source_items where available_at>now()"),5)
        self.assertEqual(self.map.value("select count(*) from assistant.source_items where available_at<=now()"),2)

    def test_bad_fetch_does_not_block_classifying_other_mail(self):
        self.map.execute("insert into assistant.source_items(source,id) values('gmail','bad'),('gmail','good')")
        classified={'id':'good','relevant':False,'notify':False,'remember':False,'title':'Routine mail','reason':'No action needed.'}
        raw={'id':'good','internalDate':'1788840000000','labelIds':['CATEGORY_UPDATES'],'payload':{}}
        with patch('engine.integrations.google._get',side_effect=[TimeoutError(),raw]):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[call('classify',items=[classified])]])).triage())
        self.assertIsNone(self.map.value("select processed_at from assistant.source_items where id='bad'"))
        self.assertEqual(self.map.value("select payload->'classification' from assistant.source_items where id='good'"),classified)

    def test_monitoring_failure_reports_once_and_recovers(self):
        from engine.background import monitoring_alert
        self.map.execute("insert into assistant.source_items(source,id,created_at) values('gmail','stuck',now()-interval '20 minutes')")
        monitoring_alert(self.map);monitoring_alert(self.map)
        self.assertEqual(self.map.value("select count(*) from assistant.attention where source='monitoring'"),1)
        self.map.execute("update assistant.source_items set processed_at=now() where source='gmail'")
        monitoring_alert(self.map)
        self.assertFalse(self.map.value("select notify from assistant.attention where source='monitoring'"))

    def test_malformed_email_does_not_block_other_mail(self):
        self.map.execute("insert into assistant.source_items(source,id) values('gmail','bad'),('gmail','good')")
        classified={'id':'good','relevant':False,'notify':False,'remember':False,'title':'Routine','reason':'No action.'}
        raw={'internalDate':'1788840000000','payload':{}}
        with patch('engine.integrations.google._get',side_effect=[{'internalDate':'invalid'},raw]):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[call('classify',items=[classified])]])).triage())
        self.assertIsNone(self.map.value("select processed_at from assistant.source_items where id='bad'"))
        self.assertIsNotNone(self.map.value("select processed_at from assistant.source_items where id='good'"))
