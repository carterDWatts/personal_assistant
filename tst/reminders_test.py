import uuid
from datetime import datetime, timedelta, timezone
from engine.reminders import Reminders, next_time
from engine.notifications import Dispatcher
from engine.tools import Tools
from engine.db import jsonb
from tst.helpers import MapTest

class reminders_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner cascade')
        owner,device=uuid.uuid4(),uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(owner,))
        self.map.execute("insert into assistant.devices(id,user_id,name) values(%s,%s,'phone')",(device,owner))
        self.map.execute("insert into assistant.push_devices(device_id,token,environment) values(%s,%s,'sandbox')",(device,'a'*64))
        self.api=Reminders(Tools(self.map,'test'))

    def make(self):
        return self.run_async(self.api.save({'title':'Call the dentist','context':'Book a cleaning before travel','timing':'exact','window_start':(datetime.now(timezone.utc)-timedelta(hours=1)).isoformat()}))

    def test_task_survives_deadline_and_delivery(self):
        item=self.make()
        class Push:
            async def send(self,row): return 200,''
        dispatcher=Dispatcher(self.map,Push());dispatcher.queue()
        self.assertTrue(self.run_async(dispatcher.deliver()))
        self.assertEqual(self.map.value('select status from memory.reminders'),'open')
        self.assertEqual(self.map.value('select count(*) from assistant.reminder_deliveries where sent_at is not null'),1)
        self.assertFalse(self.run_async(dispatcher.deliver()))
        self.assertTrue(self.map.value('select next_notify_at>now() from memory.reminders'))

    def test_done_cancels_unsent_push_and_replay_is_safe(self):
        item=self.make();dispatcher=Dispatcher(self.map);dispatcher.queue()
        args={'id':str(item['id']),'version':item['version'],'action':'done'}
        self.run_async(self.api.act(args));self.run_async(self.api.act(args))
        self.assertTrue(self.run_async(dispatcher.deliver()))
        self.assertEqual(self.map.value('select status from memory.reminders'),'completed')
        self.assertEqual(self.map.value('select count(*) from assistant.reminder_deliveries where cancelled_at is not null'),1)

    def test_snooze_and_current_context_version(self):
        item=self.make();before=self.map.value('select version from memory.context_version')
        later=(datetime.now(timezone.utc)+timedelta(days=3)).isoformat()
        self.run_async(self.api.act({'id':str(item['id']),'version':1,'action':'snooze','until':later}))
        self.assertGreater(self.map.value('select version from memory.context_version'),before)
        Dispatcher(self.map).queue()
        self.assertEqual(self.map.value('select count(*) from assistant.reminder_deliveries'),0)

    def test_weekly_and_long_term_checks_stay_sparse(self):
        now=datetime(2026,9,7,9,tzinfo=timezone.utc)
        result=next_time('week',now,72,'UTC',now)
        self.assertEqual(result,datetime(2026,9,10,12,tzinfo=timezone.utc))
        result=next_time('someday',now,168,'UTC',now)
        self.assertEqual(result.day,14)

    def test_severity_does_not_invent_a_deadline(self):
        now=datetime.now(timezone.utc)
        item=self.run_async(self.api.save({'title':'Renew documents','context':'Needed before travel next month','timing':'week','window_start':(now+timedelta(days=7)).isoformat(),'severity':'high'}))
        self.assertEqual(item['severity'],'high')
        self.assertIsNone(item['window_end'])
        self.assertGreater(item['next_notify_at'],now+timedelta(days=6))

    def test_read_email_cancels_notice_before_delivery(self):
        from unittest.mock import patch
        self.map.execute("insert into assistant.attention(source,source_id,title,detail,notify) values('gmail','read-email','A change','You already read it',true)")
        class Push:
            async def send(self,row): raise AssertionError('Must not notify for read mail')
        with patch('engine.integrations.google._get',return_value={'labelIds':[]}):
            self.assertTrue(self.run_async(Dispatcher(self.map,Push()).attention()))
        self.assertEqual(self.map.value('select count(*) from assistant.attention_deliveries where cancelled_at is not null'),1)
