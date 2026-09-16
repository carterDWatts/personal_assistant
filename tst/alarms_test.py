from datetime import datetime, timedelta, timezone
import asyncio
from unittest.mock import patch, AsyncMock
import uuid
from engine.db import jsonb
from engine.reminders import Reminders
from engine.tools import Tools
from tst.helpers import MapTest

class alarms_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner=uuid.uuid4();self.device=uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.rpc('register',{'name':'Test phone'})
        self.api=Reminders(Tools(self.map,'test'))
        self.args={'title':'Switch to interview prep','context':'Leave half an hour before the interview.',
                   'kind':'task','timing':'exact','window_start':(datetime.now(timezone.utc)+timedelta(hours=1)).isoformat(),'alarm':True}
    def rpc(self,action,args=None,device=None):
        return self.map.value('select public.assistant_client(%s,%s,%s,%s)',(self.owner,device or self.device,action,jsonb(args or {})))
    def test_timer_schedules_ringing_and_waits_for_phone_receipt(self):
        async def check():
            task=asyncio.create_task(self.api.timer({'title':'Timer','seconds':120}))
            await asyncio.sleep(0)
            row=self.rpc('alarm_sync')['alarms'][0]
            self.assertTrue(row['enabled'])
            self.rpc('alarm_receipt',{'id':row['id'],'version':row['version'],'status':'scheduled'})
            result=await task
            self.assertTrue(result['alarm_ready'])
            self.assertEqual(result['delivery'],'alarm')
            self.assertEqual(result['kind'],'check_in')
            self.assertAlmostEqual((result['alarm_at']-datetime.now(timezone.utc)).total_seconds(),120,delta=3)
        self.run_async(check())
    def test_timer_upgrades_notification_and_permission_denial_is_not_ready(self):
        item=self.run_async(self.api.save({**self.args,'alarm':False,'severity':'high','followup_hours':24}))
        self.assertEqual(item['delivery'],'notification')
        self.assertFalse(item['alarm_ready'])
        async def check():
            task=asyncio.create_task(self.api.timer({'id':str(item['id']),'version':1,'title':item['title'],'at':self.args['window_start']}))
            await asyncio.sleep(0)
            row=self.rpc('alarm_sync')['alarms'][0]
            self.rpc('alarm_receipt',{'id':row['id'],'version':row['version'],'status':'denied'})
            result=await task
            self.assertFalse(result['alarm_ready'])
            self.assertEqual(result['alarm_delivery'][0]['status'],'denied')
            self.assertEqual(result['context'],self.args['context'])
            self.assertEqual(result['severity'],'high')
            self.assertEqual(result['followup_hours'],24)
            self.assertEqual(self.map.value('select count(*) from memory.reminders'),1)
        self.run_async(check())
    def test_timer_schema_rejects_ambiguous_time_and_worker_cannot_use_timer_tool(self):
        from jsonschema import validate,ValidationError
        spec=next(s for s in self.api.specs() if s.name=='timer_set')
        for change in ({},{'seconds':0},{'seconds':30,'at':self.args['window_start']},{'id':str(uuid.uuid4()),'seconds':30}):
            with self.assertRaises(ValidationError):validate({'title':'Timer',**change},spec.schema)
        self.assertNotIn('timer_set',[s.name for s in self.api.specs(scheduling=False)])
    def test_timer_without_phone_never_claims_ready_even_after_memory_race(self):
        item=self.run_async(self.api.save({**self.args,'alarm':False}))
        with patch('engine.reminders.asyncio.sleep',new_callable=AsyncMock):
            result=self.run_async(self.api.timer({'title':item['title'],'at':self.args['window_start']}))
        self.assertEqual(result['id'],item['id'])
        self.assertIsNotNone(result['alarm_at'])
        self.assertEqual(result['delivery'],'alarm')
        self.assertFalse(result['alarm_ready'])
    def test_alarm_requires_device_confirmation_and_keeps_context(self):
        item=self.run_async(self.api.save(self.args))
        self.assertFalse(item['alarm_ready'])
        row=self.rpc('alarm_sync')['alarms'][0]
        self.assertTrue(row['enabled']);self.assertEqual(row['title'],self.args['title'])
        self.rpc('alarm_receipt',{'id':str(item['id']),'version':1,'status':'scheduled'})
        self.assertTrue(self.run_async(self.api.list({}))[0]['alarm_ready'])
        self.assertEqual(self.map.value('select context from memory.reminders'),self.args['context'])
    def test_stopping_alarm_does_not_complete_task_or_rearm(self):
        item=self.run_async(self.api.save(self.args))
        self.rpc('alarm_receipt',{'id':str(item['id']),'version':1,'status':'dismissed'})
        self.assertEqual(self.map.value('select status from memory.reminders'),'open')
        self.assertEqual(self.rpc('alarm_sync')['alarms'][0]['receipt'],'dismissed')
        self.assertFalse(self.run_async(self.api.list({}))[0]['alarm_ready'])
    def test_snooze_changes_alarm_time_and_rejects_old_receipt(self):
        item=self.run_async(self.api.save(self.args))
        later=(datetime.now(timezone.utc)+timedelta(hours=2)).isoformat()
        self.rpc('reminder_action',{'id':str(item['id']),'version':1,'action':'snooze','until':later})
        self.assertEqual(self.map.value('select alarm_at=next_notify_at from memory.reminders'),True)
        with self.assertRaises(Exception):self.rpc('alarm_receipt',{'id':str(item['id']),'version':1,'status':'scheduled'})
        row=self.rpc('alarm_sync')['alarms'][0];self.assertEqual(row['version'],2)
    def test_completion_cancels_native_alarm_but_not_unrelated_reminders(self):
        item=self.run_async(self.api.save(self.args))
        self.rpc('alarm_receipt',{'id':str(item['id']),'version':1,'status':'scheduled'})
        self.rpc('reminder_action',{'id':str(item['id']),'version':1,'action':'done'})
        row=self.rpc('alarm_sync')['alarms'][0];self.assertFalse(row['enabled'])
        self.rpc('alarm_receipt',{'id':str(item['id']),'version':2,'status':'cancelled'})
        self.assertEqual(self.rpc('alarm_sync')['alarms'],[])
    def test_severity_alone_never_schedules_an_alarm(self):
        self.run_async(self.api.save({**self.args,'alarm':False,'severity':'critical'}))
        self.assertEqual(self.rpc('alarm_sync')['alarms'],[])
    def test_past_and_nonspecific_alarms_are_rejected(self):
        for change in ({'timing':'day'},{'window_start':(datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat()}):
            with self.assertRaises(ValueError):self.run_async(self.api.save({**self.args,**change}))
    def test_revoked_or_foreign_device_cannot_read_or_confirm(self):
        self.run_async(self.api.save(self.args))
        with self.assertRaises(Exception):self.rpc('alarm_sync',device=uuid.uuid4())
        self.map.execute('update assistant.devices set revoked_at=now() where id=%s',(self.device,))
        with self.assertRaises(Exception):self.rpc('alarm_sync')
    def test_client_and_receipts_are_not_publicly_callable(self):
        self.assertFalse(self.map.value("select has_function_privilege('anon','public.assistant_client(uuid,uuid,text,jsonb)','execute')"))
        self.assertFalse(self.map.value("select has_table_privilege('authenticated','assistant.alarm_receipts','select')"))
