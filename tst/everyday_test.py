import asyncio
import json
import uuid
import unittest
from types import SimpleNamespace
from unittest.mock import patch, Mock
from engine.integrations import utilities, workspace_write, places
from engine.tools import ToolError, ConnectionRequired
from tst.helpers import MapTest
from tst.spotify_test import spotify_delivery_test

class utility_test(unittest.TestCase):
    def test_arithmetic_is_decimal_and_cannot_execute_code(self):
        self.assertEqual(utilities.calculate({'expression':'0.1+0.2'})['result'],'0.3')
        for text in ["__import__('os').system('id')",'9**999999999','1/0','float("inf")','[1]*1000000']:
            with self.assertRaises(ToolError):utilities.calculate({'expression':text})
    def test_units_and_dst(self):
        self.assertEqual(utilities.convert({'value':'32','from_unit':'f','to_unit':'c'})['value'],'0.00')
        with self.assertRaises(ToolError):utilities.convert({'value':'1','from_unit':'kg','to_unit':'mi'})
        result=utilities.time_at({'at':'2026-11-01T08:30:00Z','zones':['America/Los_Angeles']})
        self.assertTrue(result['times']['America/Los_Angeles'].endswith('-07:00'))
        with self.assertRaises(ToolError):utilities.time_at({'at':'2026-11-01T01:30:00','zones':['America/Los_Angeles']})
    def test_spreadsheet_stale_check_prevents_overwrite(self):
        with patch.object(workspace_write,'request',return_value={'values':[['old']]}) as call:
            with self.assertRaises(ToolError):workspace_write.sheets({'action':'write','spreadsheet_id':'id','range':'A1','expected_fingerprint':'stale','values':[['new']]})
            self.assertEqual(call.call_count,1)
    def test_document_edit_uses_revision_and_partial_create_has_id(self):
        with patch.object(workspace_write,'request',return_value={}) as call:
            workspace_write.documents({'action':'append','document_id':'id','revision_id':'rev','text':'hello'})
            self.assertEqual(call.call_args.args[4]['writeControl'],{'requiredRevisionId':'rev'})
        with patch.object(workspace_write,'request',side_effect=[{'documentId':'id'},TimeoutError()]):
            result=workspace_write.documents({'action':'create','title':'Example','text':'hello'})
            self.assertTrue(result['partial']);self.assertEqual(result['document_id'],'id')

class write_journal_test(MapTest):
    def setUp(self):
        super().setUp();self.map.execute('truncate assistant.external_operations')
        self.journal=workspace_write.WorkspaceWrites(SimpleNamespace(map=self.map,message_id=123))
    def test_receipt_replay_and_uncertain_write_does_not_repeat(self):
        fn=Mock(return_value={'id':'saved'})
        for _ in range(2):self.assertEqual(asyncio.run(self.journal.execute('example',fn,{'action':'create'})),{'id':'saved'})
        self.assertEqual(fn.call_count,1)
        fn=Mock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):asyncio.run(self.journal.execute('lost',fn,{'action':'create'}))
        with self.assertRaises(ToolError):asyncio.run(self.journal.execute('lost',fn,{'action':'create'}))
        self.assertEqual(fn.call_count,1)
    def test_connection_failure_can_resume_after_permission(self):
        fn=Mock(side_effect=[ConnectionRequired('Connect','google_tasks_write'),{'id':'saved'}])
        with self.assertRaises(ConnectionRequired):asyncio.run(self.journal.execute('example',fn,{'action':'create'}))
        self.assertEqual(asyncio.run(self.journal.execute('example',fn,{'action':'create'})),{'id':'saved'})
    def test_new_edit_scopes_are_separate_and_discoverable(self):
        from engine.integrations.catalog import GOOGLE_GRANTS
        actions={v['action'] for v in GOOGLE_GRANTS.values()}
        self.assertTrue({'google_documents_write','google_tasks_write'}<=actions)

class device_test(spotify_delivery_test):
    def setUp(self):
        super().setUp()
        self.map.execute('insert into assistant.device_commands(id,user_id,device_id,turn_id,command) values(%s,%s,%s,%s,%s)',
            (self.command,self.owner,self.device,self.turn,json.dumps({'action':'places','query':'coffee'})))
    def command_call(self,action,result=None,device=None):
        return self.map.value('select public.assistant_device(%s,%s,%s,%s)',(self.owner,device or self.device,action,json.dumps({'command_id':str(self.command),'result':result})))
    def test_command_claim_is_one_time_and_result_is_idempotent(self):
        self.assertEqual(self.command_call('claim')['command']['query'],'coffee')
        self.assertEqual(self.command_call('claim'),{'state':'claimed'})
        self.command_call('finish',{'places':[]});self.command_call('finish',{'places':['wrong']})
        self.assertEqual(self.map.value('select result from assistant.device_commands where id=%s',(self.command,)),{'places':[]})
    def test_expired_cancelled_and_replaced_host_commands_cannot_play(self):
        for sql in ["update assistant.device_commands set expires_at=now()-interval '1 second'",'update assistant.turns set cancel_requested=true','update assistant.host set worker_id=gen_random_uuid()']:
            with self.map.conn.transaction(force_rollback=True):
                self.map.execute(sql);self.assertEqual(self.command_call('claim'),{'state':'expired'})
    def test_untrusted_result_size_and_database_permissions(self):
        self.command_call('claim')
        import psycopg
        with self.assertRaises(psycopg.Error):self.command_call('finish',{'error':'x'*33000})
        for role in ('anon','authenticated'):
            self.assertFalse(self.map.value("select has_function_privilege(%s,'public.assistant_device(uuid,uuid,text,jsonb)','EXECUTE')",(role,)))
    def test_host_handoff_returns_phone_receipt_and_expires_on_completion_or_cancel(self):
        async def exercise():
            async def call(fn,*args):return fn(*args)
            host=SimpleNamespace(relay=self.relay,active=self.turn,call=call)
            task=asyncio.create_task(places.phone_command(host,{'action':'location'}));await asyncio.sleep(0)
            row=self.map.row("select id from assistant.device_commands where command->>'action'='location'")
            self.command=row['id'];self.command_call('claim');self.command_call('finish',{'latitude':1,'longitude':2})
            self.assertEqual((await asyncio.wait_for(task,2))['latitude'],1)
            self.assertEqual(self.command_call('claim'),{'state':'expired'})
        asyncio.run(exercise())

class watch_test(MapTest):
    def setUp(self):
        super().setUp();self.map.execute('truncate assistant.price_watches,assistant.outbound cascade')
    def test_threshold_notifies_once_and_failures_never_invent_prices(self):
        from engine.integrations import watches
        row=self.map.row("insert into assistant.price_watches(url,offer_key,title,currency,threshold) values('https://example.com/item','offer','Example','USD',20) returning id")
        with patch.object(watches,'inspect',return_value={'offers':[{'key':'offer','currency':'USD','price':'19'}]}),patch('engine.outbound.post') as post:
            asyncio.run(watches.poll(self.map));asyncio.run(watches.poll(self.map));self.assertEqual(post.call_count,1)
        self.assertIsNotNone(self.map.value('select notified_at from assistant.price_watches where id=%s',(row['id'],)))
        self.map.execute('update assistant.price_watches set notified_at=null,next_check=now()')
        with patch.object(watches,'inspect',return_value={'offers':[]}),patch('engine.outbound.post') as post:
            asyncio.run(watches.poll(self.map));post.assert_not_called()
        self.assertIsNotNone(self.map.value('select last_error from assistant.price_watches where id=%s',(row['id'],)))
    def test_offer_parser_does_not_use_aggregate_or_unidentified_prices(self):
        from engine.integrations import watches
        from contextlib import contextmanager
        @contextmanager
        def page(*args,**kwargs):
            yield ('https://example.com/item',SimpleNamespace(status=200,read=lambda n:b'<script type="application/ld+json">{"@type":"Product","name":"Example","offers":[{"@type":"AggregateOffer","lowPrice":"1","priceCurrency":"USD"},{"@type":"Offer","price":"15.99","priceCurrency":"USD"}]}</script>'))
        with patch.object(watches,'open_public',page):result=watches.inspect({'url':'https://example.com/item'})
        self.assertEqual(len(result['offers']),1);self.assertEqual(result['offers'][0]['price'],'15.99')

class location_reminder_test(MapTest):
    def test_location_delivery_does_not_complete_commitment(self):
        from engine.relay import Relay
        from engine.db import jsonb
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        owner=uuid.uuid4();device=uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(owner,))
        self.map.value("select public.assistant_client(%s,%s,'register',%s)",(owner,device,jsonb({'name':'Phone'})))
        row=self.map.row("insert into memory.reminders(title,timing,window_start,next_notify_at,followup_hours,timezone,location_trigger) values('Pick up package','day',now(),now(),24,'America/Los_Angeles',%s) returning id,version",(jsonb({'device_id':str(device),'event':'arrival'}),))
        args=jsonb({'id':str(row['id']),'version':row['version']})
        self.assertTrue(self.map.value("select public.assistant_locations(%s,%s,'delivered',%s)",(owner,device,args))['recorded'])
        result=self.map.row('select status,location_trigger,next_notify_at>now() as later from memory.reminders where id=%s',(row['id'],))
        self.assertEqual(result['status'],'open');self.assertTrue(result['later']);self.assertIsNone(result['location_trigger'])
        self.assertFalse(self.map.value("select public.assistant_locations(%s,%s,'delivered',%s)",(owner,device,args))['recorded'])
        self.map.execute('truncate assistant.owner,assistant.host cascade')

    def test_reconfigured_location_rejects_old_receipt_and_edits_clear_trigger(self):
        from engine.db import jsonb
        from engine.integrations.location_reminders import LocationReminders
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        owner,device=uuid.uuid4(),uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(owner,))
        self.map.value("select public.assistant_client(%s,%s,'register',%s)",(owner,device,jsonb({'name':'Phone'})))
        row=self.map.row("insert into memory.reminders(title,timing,window_start,next_notify_at,followup_hours,timezone) values('Parcel','day',now(),now(),24,'America/Los_Angeles') returning id,version")
        async def schedule(args):
            self.assertEqual(args['version'],row['version']+1)
            return {'scheduled':True,'device_id':str(device)}
        service=LocationReminders(SimpleNamespace(map=self.map),schedule)
        asyncio.run(service.configure({**row,'latitude':47.6,'longitude':-122.3,'radius':200,'event':'arrival'}))
        current=self.map.row('select * from memory.reminders where id=%s',(row['id'],))
        self.assertEqual(current['version'],row['version']+1);self.assertIsNotNone(current['location_trigger'])
        self.assertFalse(self.map.value("select public.assistant_locations(%s,%s,'delivered',%s)",(owner,device,jsonb({'id':str(row['id']),'version':row['version']})))['recorded'])
        sync=self.map.value("select public.assistant_locations(%s,%s,'sync','{}')",(owner,device))
        self.assertEqual(sync['reminders'][0]['version'],current['version'])
        self.map.execute('update memory.reminders set version=version+1 where id=%s',(row['id'],))
        self.assertIsNone(self.map.value('select location_trigger from memory.reminders where id=%s',(row['id'],)))
        self.map.execute('truncate assistant.owner,assistant.host cascade')
