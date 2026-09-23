from datetime import date,timedelta
from engine.conversation import Conversation
from engine.tools import Tools,ToolError
from engine import review_queue,routine,context
from tst.helpers import MapTest


class routine_review_test(MapTest):
    def setUp(self):
        super().setUp()
        self.conv=Conversation(self.map,'test','fake')
        self.segment=self.conv.open_segment('morning')
        self.tools=Tools(self.map,'test')
        self.tool=routine.spec(self.tools,self.segment)

    def source(self,text):
        self.tools.message_id=self.conv.record(self.segment,'user',text)

    def plan(self,text='Follow up on an unanswered application'):
        return self.map.row("insert into memory.plans(day,item,status,origin,created_by) values(current_date-14,%s,'planned','user','test') returning *",(text,))

    def question(self,text='Has the recruiter confirmed the next step?',score=3):
        return self.run_async(self.tools.question_add({'text':text,'score':score}))

    def decision(self,item,**changes):
        return {k:item[k] for k in ('kind','ref_id','revision')} | {'action':'defer','reason':'Check the thread first.','days':3} | changes

    def test_spoken_start_commands_are_not_future_mentions(self):
        for text in ["OK, let's start the morning",'I will start the morning','Start my morning routine','Can we start the morning?']:
            self.assertEqual(routine.requested(text),'morning')
        for text in ['Do not start the morning','I will start the morning tomorrow','What did we do this morning?']:
            self.assertIsNone(routine.requested(text))

    def test_finished_agenda_leads_into_unresolved_work_without_completing_it(self):
        p=self.plan()
        self.run_async(self.tool.fn({'steps':['Plan today']}))
        state=self.run_async(self.tool.fn({'completed_step':'Plan today'}))
        self.assertEqual(state['state'],'review')
        self.assertEqual(state['review_queue'][0]['ref_id'],str(p['id']))
        self.assertEqual(self.map.value('select status from memory.plans where id=%s',(p['id'],)),'planned')

    def test_acknowledgment_advances_but_an_answer_to_a_question_does_not_skip_it(self):
        self.run_async(self.tool.fn({'steps':['Calendar','Updates','Review']}))
        self.conv.record(self.segment,'assistant','Gym is 5 to 6. There is a break afterward.')
        self.run_async(routine.steer(self.tools,self.segment,'Correct'))
        self.assertEqual(routine.progress(self.map,self.segment)['current'],'Updates')
        self.conv.record(self.segment,'assistant','Was the login yours?')
        self.run_async(routine.steer(self.tools,self.segment,'Yes'))
        self.assertEqual(routine.progress(self.map,self.segment)['current'],'Updates')

    def test_dismissal_preserves_unknown_outcome_and_new_evidence_restores_review(self):
        p=self.plan('An old routine attendance block')
        item=review_queue.candidates(self.map)[0]
        with self.assertRaises(ToolError): review_queue.decide(self.tools,self.decision(item,action='dismiss'))
        self.source('That old attendance question does not matter. Stop asking it.')
        review_queue.decide(self.tools,self.decision(item,action='dismiss',reason='User does not need historical attendance tracked.'))
        self.assertEqual(review_queue.candidates(self.map),[])
        self.assertEqual(self.map.value('select status from memory.plans where id=%s',(p['id'],)),'planned')
        self.assertFalse(self.map.rows('select * from memory.plan_notes(current_date)'))
        self.map.execute('update memory.plans set item=%s where id=%s',('This attendance now affects a payroll dispute',p['id']))
        self.assertEqual(len(review_queue.candidates(self.map)),1)
        with self.assertRaises(ToolError): review_queue.decide(self.tools,self.decision(item))

    def test_critical_question_cannot_be_buried_by_background_review(self):
        self.question()
        item=review_queue.candidates(self.map)[0]
        review_queue.decide(self.tools,self.decision(item,days=7))
        self.assertEqual(self.map.value('select review_after from memory.review_decisions'),date.today()+timedelta(days=1))
        self.assertEqual(review_queue.candidates(self.map),[])
        self.assertIsNone(self.map.value('select closed_at from memory.questions'))
        self.map.execute("insert into memory.review_decisions(kind,ref_id,revision,action,reason,review_after) values('question',%s,%s,'defer','Previous deferral expired',current_date)",(item['ref_id'],item['revision']))
        self.assertEqual(len(review_queue.candidates(self.map)),1)

    def test_focus_survives_reconnection_and_skip_does_not_answer_it(self):
        q=self.question()
        self.run_async(self.tool.fn({'steps':['Updates']}))
        item=review_queue.candidates(self.map)[0]
        focus={k:item[k] for k in ('kind','ref_id','revision')}
        self.run_async(self.tool.fn({'focus':focus}))
        self.assertEqual(routine.progress(self.map,self.segment)['review_focus'],focus)
        self.run_async(routine.steer(self.tools,self.segment,'Next'))
        self.assertIsNone(routine.progress(self.map,self.segment)['review_focus'])
        self.assertIsNone(self.map.value('select closed_at from memory.questions where id=%s',(q['id'],)))

    def test_user_can_finish_without_losing_pending_commitments(self):
        self.plan()
        self.run_async(self.tool.fn({'steps':['Plan']}))
        self.source('That is enough for now.')
        self.run_async(self.tool.fn({'finish':True}))
        self.assertEqual(routine.progress(self.map,self.segment)['state'],'complete')
        self.assertEqual(len(review_queue.candidates(self.map)),1)

    def test_dismissed_attendance_does_not_restart_background_reconciliation(self):
        from engine.plan_review import PlanReview
        self.plan('Old attendance')
        self.map.execute('update memory.plan_reviews set available_at=now()')
        self.source('Stop checking that old attendance.')
        review_queue.decide(self.tools,self.decision(review_queue.candidates(self.map)[0],action='dismiss'))
        self.assertFalse(PlanReview(self.map).pending())

    def test_nightly_must_review_existing_work_before_adding_more(self):
        from engine.background import Background
        from datetime import datetime
        from zoneinfo import ZoneInfo
        from unittest.mock import patch
        from tst.helpers import FakeRuntime,call
        from engine import config
        self.question()
        self.map.execute('truncate assistant.maintenance_runs')
        class Clock(datetime):
            @classmethod
            def now(cls,tz=None): return datetime.combine(date.today(),datetime.min.time(),ZoneInfo(config.TIMEZONE)).replace(hour=4)
        with patch('engine.background.datetime',Clock):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[call('organize',questions=[])]])).nightly())
        self.assertIsNone(self.map.value('select completed_at from assistant.maintenance_runs'))
        self.map.execute("update assistant.maintenance_runs set available_at='2020-01-01'")
        item=review_queue.candidates(self.map)[0]
        with patch('engine.background.datetime',Clock):
            self.run_async(Background(self.map,lambda _:FakeRuntime([[call('organize',questions=[],reviews=[self.decision(item,action='keep')])]])).nightly())
        self.assertIsNotNone(self.map.value('select completed_at from assistant.maintenance_runs'))
        self.assertIsNone(self.map.value('select closed_at from memory.questions'))

    def test_small_changes_do_not_resend_large_memory_sections(self):
        original='Standing rules\n'+'\n'.join(f'Preference number {i}: keep this exact standing instruction (rule {i})' for i in range(100))
        delta=context.update({'rules':original},{'rules':original+'\nNew preference (rule 101)'})
        self.assertLess(len(delta),500)
        self.assertIn('New preference',delta)
        self.assertNotIn('Preference number 50',delta)
        self.assertEqual(context.update({'rules':original},{'rules':original}),'Memory checked; no changes.')


import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock,patch
from engine.host import Host


class morning_routing_test(unittest.IsolatedAsyncioTestCase):
    async def test_spoken_request_enters_real_routine_and_keeps_user_message(self):
        host=Host.__new__(Host)
        host.prepare_session=AsyncMock()
        host.session=SimpleNamespace(send=AsyncMock())
        host.stream=object()
        with patch('engine.morning.prepare',AsyncMock(return_value='Fresh calendar')):
            await host.answer({'text':'I will start the morning','mode':'talk','speech':True})
        host.prepare_session.assert_awaited_once_with(None,'morning')
        self.assertEqual(host.session.send.await_args.kwargs['role'],'user')
        self.assertIn('Fresh calendar',host.session.send.await_args.kwargs['extra_context'])
