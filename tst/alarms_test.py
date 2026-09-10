from datetime import datetime, timedelta, timezone
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
