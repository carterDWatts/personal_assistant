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

    def test_trashed_email_cancels_notice_before_delivery(self):
        from unittest.mock import patch
        self.map.execute("insert into assistant.attention(source,source_id,title,detail,notify) values('gmail','read-email','A change','You already read it',true)")
        class Push:
            async def send(self,row): raise AssertionError('Must not notify for trashed mail')
        with patch('engine.integrations.google._get',return_value={'labelIds':['TRASH']}):
            self.assertTrue(self.run_async(Dispatcher(self.map,Push()).attention()))
        self.assertEqual(self.map.value('select count(*) from assistant.attention_deliveries where cancelled_at is not null'),1)

    def test_read_email_keeps_important_notice_eligible(self):
        from unittest.mock import patch
        self.map.execute("insert into assistant.attention(source,source_id,title,detail,notify) values('gmail','read-important','A change','Still important',true)")
        class Push:
            async def send(self,row):return 200,None
        with patch('engine.integrations.google._get',return_value={'labelIds':['INBOX']}):
            self.assertTrue(self.run_async(Dispatcher(self.map,Push()).attention()))
        self.assertEqual(self.map.value('select count(*) from assistant.attention_deliveries where sent_at is not null'),1)

    def test_internal_context_is_composed_before_delivery(self):
        item=self.make()
        self.map.execute("update memory.reminders set context='Carter wants me to prepare his brief' where id=%s",(item['id'],))
        async def compose(map_,record):return 'Here is the update you asked for.'
        class Push:
            async def send(self,row):
                assert row['title']=='Here is the update you asked for.'
                return 200,''
        dispatcher=Dispatcher(self.map,Push(),compose=compose);dispatcher.queue()
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        self.run_async(dispatcher.deliver())
        self.assertEqual(self.map.value('select content from memory.messages order by id desc limit 1'),'Here is the update you asked for.')

    def test_completion_during_composition_prevents_stale_message(self):
        item=self.make()
        async def compose(map_,record):
            await self.api.act({'id':str(item['id']),'version':item['version'],'action':'done'})
            return 'This is no longer needed.'
        class Push:
            async def send(self,row):raise AssertionError('Completed reminder must not be sent')
        dispatcher=Dispatcher(self.map,Push(),compose=compose);dispatcher.queue()
        self.run_async(dispatcher.deliver())
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)

    def check_in(self, expired=False):
        now=datetime.now(timezone.utc)
        return self.run_async(self.api.save({'kind':'check_in','title':'End of work check-in','context':'Tell me what comes next','timing':'exact','window_start':(now-timedelta(hours=1)).isoformat(),'window_end':(now+timedelta(minutes=-1 if expired else 15)).isoformat()}))

    def test_expired_check_in_never_queues_but_task_still_does(self):
        self.check_in(expired=True)
        task=self.make()
        self.map.execute("update memory.reminders set window_end=now()-interval '10 minutes' where id=%s",(task['id'],))
        Dispatcher(self.map).queue()
        self.assertEqual(self.map.rows('select reminder_id from assistant.reminder_deliveries'),[{'reminder_id':task['id']}])
        self.assertEqual(self.map.value("select count(*) from memory.reminders where status='open'"),2)

    def test_check_in_does_not_repeat_even_when_clock_is_still_due(self):
        self.check_in()
        class Push:
            async def send(self,row):return 200,''
        dispatcher=Dispatcher(self.map,Push());dispatcher.queue()
        self.run_async(dispatcher.deliver())
        dispatcher.queue()
        self.assertEqual(self.map.value('select count(*) from assistant.reminder_deliveries'),1)
        self.assertFalse(self.run_async(dispatcher.deliver()))

    def test_expired_queued_check_in_skips_model_and_push(self):
        item=self.check_in()
        async def compose(*args):raise AssertionError('No model call for expired check-in')
        dispatcher=Dispatcher(self.map,compose=compose);dispatcher.queue()
        self.map.execute("update memory.reminders set window_end=now()-interval '1 minute' where id=%s",(item['id'],))
        self.run_async(dispatcher.deliver())
        self.assertEqual(self.map.value('select count(*) from assistant.reminder_deliveries where cancelled_at is not null'),1)
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)

    def test_window_expiring_during_composition_prevents_delivery(self):
        item=self.check_in()
        async def compose(*args):
            self.map.execute("update memory.reminders set window_end=now()-interval '1 minute' where id=%s",(item['id'],))
            return 'Too late'
        dispatcher=Dispatcher(self.map,compose=compose);dispatcher.queue()
        self.run_async(dispatcher.deliver())
        self.assertEqual(self.map.value('select count(*) from assistant.reminder_deliveries where cancelled_at is not null'),1)
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)

    def test_context_change_during_composition_requires_fresh_review(self):
        self.make()
        async def compose(*args):
            from engine.outbound import post
            post(self.map,'changed-plan','The plan changed while this was being prepared.')
            return 'Based on the old plan'
        dispatcher=Dispatcher(self.map,compose=compose);dispatcher.queue()
        self.run_async(dispatcher.deliver())
        self.assertEqual(self.map.value("select count(*) from assistant.outbound where key like 'reminder:%%'"),0)
        self.assertTrue(self.map.value('select retry_at>now() from assistant.reminder_deliveries'))

    def test_withholding_does_not_complete_or_drop_the_task(self):
        self.make()
        async def compose(*args):return None
        dispatcher=Dispatcher(self.map,compose=compose);dispatcher.queue()
        self.run_async(dispatcher.deliver())
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        self.assertTrue(self.map.value("select status='open' and next_notify_at>now() from memory.reminders"))
        self.assertTrue(self.map.value('select cancelled_at is not null from assistant.reminder_deliveries'))

    def test_composer_gets_current_time_and_conversation_and_can_withhold(self):
        from engine.reminder_message import compose
        from engine.runtime import Event
        from tst.helpers import FakeRuntime
        from engine.outbound import post
        item=self.make()
        post(self.map,'recent-change','Tonight I suggested resting instead.')
        async def withhold(runtime):
            await runtime.tools['withhold_reminder'].fn({'reason':'Recent plan changed'})
            return Event('text',text='This text must not be delivered.')
        runtime=FakeRuntime([[withhold]])
        self.assertIsNone(self.run_async(compose(self.map,item,factory=lambda _:runtime)))
        self.assertIn('current_local_time',runtime.sent[0])
        self.assertIn('Tonight I suggested resting instead.',runtime.sent[0])
        self.assertIn('past_start',runtime.sent[0])

    def test_push_retry_does_not_replay_message_after_conversation_changes(self):
        self.make()
        class Push:
            calls=0
            async def send(self,row):
                self.calls+=1
                return 503,'unavailable'
        push=Push();dispatcher=Dispatcher(self.map,push);dispatcher.queue()
        self.run_async(dispatcher.deliver())
        conversation=self.map.value("insert into memory.conversations(agent,device) values('test','test') returning id")
        self.map.execute("insert into memory.messages(conversation_id,seq,role,content) values(%s,1,'user','Plans changed, I am staying home.')",(conversation,))
        self.map.execute('update assistant.reminder_deliveries set retry_at=now()')
        self.run_async(dispatcher.deliver())
        self.assertEqual(push.calls,1)
        self.assertTrue(self.map.value('select cancelled_at is not null from assistant.reminder_deliveries'))
        self.assertEqual(self.map.value('select status from memory.reminders'),'open')
