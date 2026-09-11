import uuid
import tempfile
import asyncio
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch
from engine.db import Map
from engine.relay import Relay
from engine.jobs import Jobs, Worker
from engine.tools import Tools, ToolError
from engine.workspace import Workspace
from engine.outbound import post
from engine.conversation import Conversation
from engine.db import jsonb
from tst.helpers import MapTest, FakeRuntime, say

class jobs_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.attention cascade')
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner=uuid.uuid4();self.device=uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.map.value("select public.assistant_client(%s,%s,'register',%s)",(self.owner,self.device,jsonb({"name":"Test"})))
        c=Conversation(self.map,'phone','codex');segment=c.open_segment('talk')
        self.tools=Tools(self.map,'phone');self.tools.message_id=c.record(segment,'user','Research this for me')
        self.jobs=Jobs(self.tools)
    def tearDown(self):
        if getattr(self,'map',None):
            self.map.execute("delete from assistant.attention where source='job'")
            self.map.execute('truncate assistant.owner,assistant.host cascade')
        super().tearDown()
    def start(self,**extra):return self.run_async(self.jobs.start({'key':'test','task':'Find a useful answer','kind':'research',**extra}))

    def answer(self, message):
        async def complete(runtime):
            await runtime.tools['job_plan'].fn({'items':[{'key':'answer','task':'Find a useful answer'}]})
            await runtime.tools['job_step'].fn({'key':'answer','status':'done','evidence':'Verified against the supplied test source.'})
            await runtime.tools['job_finish'].fn({'message':message})
            return say(message)
        return complete

    def test_local_and_hosted_runners_respect_the_current_lease(self):
        from engine.jobs import run
        relay = Relay(self.map)
        relay.acquire()
        host = SimpleNamespace(ready=asyncio.Event(), stopping=asyncio.Event(), relay=relay)
        host.ready.set()

        async def cycle(runner, expected):
            connection = Map(self.map.url)
            worker = Mock(once=AsyncMock())
            with patch('engine.jobs.Map', return_value=connection), patch('engine.jobs.Worker', return_value=worker), \
                 patch('engine.jobs.asyncio.sleep', side_effect=asyncio.CancelledError):
                with self.assertRaises(asyncio.CancelledError):
                    await run(self.map.url, runner)
            self.assertEqual(worker.once.await_count, expected)
            self.assertTrue(connection.conn.closed)

        self.run_async(cycle(None, 0))
        self.run_async(cycle(host, 1))
        relay.release()
        self.run_async(cycle(None, 1))
        self.run_async(cycle(host, 0))

    def test_retry_does_not_spawn_again_and_cancel_is_terminal(self):
        first=self.start();self.assertEqual(first,self.start())
        self.run_async(self.jobs.cancel({'id':str(first['id'])}))
        self.assertFalse(self.run_async(Worker(self.map).once()))
        self.assertEqual(self.map.value('select count(*) from assistant.jobs'),1)
    def test_completion_is_one_message_with_replayable_reference(self):
        first=self.start();runtime=FakeRuntime([[self.answer('I found the answer.')]])
        worker=Worker(self.map,lambda _:lambda **kw:runtime)
        self.assertTrue(self.run_async(worker.once()))
        self.assertFalse(self.run_async(worker.once()))
        self.assertNotIn('job_start',runtime.tools)
        self.assertNotIn('google_calendar_create_event',runtime.tools)
        self.assertEqual(self.map.value('select status from assistant.jobs'),'completed')
        row=self.map.row('select * from assistant.outbound')
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),1)
        history=self.map.value("select public.assistant_client(%s,%s,'bootstrap','{}')",(self.owner,self.device))['history']
        self.assertNotIn('I found the answer.',[m['content'] for m in history])
        inbox=self.map.value("select public.assistant_client(%s,%s,'inbox','{}')",(self.owner,self.device))['messages']
        self.assertEqual(inbox[0]['content'],'I found the answer.')
        self.assertEqual(inbox[0]['payload']['reference'],row['reference'])
        retrieved=self.map.value("select public.assistant_client(%s,%s,'notification_message',%s)",(self.owner,self.device,jsonb(row['reference'])))
        self.assertEqual(retrieved['message']['id'],row['message_id'])
    def test_duplicate_outbound_and_failed_job_do_not_fake_success(self):
        self.start();runtime=FakeRuntime([])
        self.run_async(Worker(self.map,lambda _:lambda **kw:runtime).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'failed')
        one=post(self.map,'same','I have an update.')
        self.assertEqual(one,post(self.map,'same','Must not duplicate'))
    def test_code_draft_is_separate_and_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as path:
            root=Path(path);(root/'engine').mkdir();f=root/'engine/test.py';f.write_text('old\n')
            w=Workspace(root)
            self.run_async(w.write({'path':'engine/test.py','content':'new\n'}))
            self.assertEqual(f.read_text(),'old\n')
            self.assertIn('+new',w.patch())
            self.run_async(w.write({'path':'ios/Assistant/Test.swift','content':'import Foundation\n'}))
            self.assertIn('ios/Assistant/Test.swift',w.patch())
            self.assertFalse((root/'ios/Assistant/Test.swift').exists())
            for bad in ['/data/secret','engine/../../secret.py','engine/.env.py']:
                with self.assertRaises(ToolError):self.run_async(w.read({'path':bad}))

    def test_failure_preserves_checkpoint_and_can_resume(self):
        first=self.start(kind='code')
        async def fail(runtime):
            await runtime.tools['job_checkpoint'].fn({'findings':'Verified source A','remaining':'Read source B'})
            raise TimeoutError('private provider detail')
        runtime=FakeRuntime([[say('Partial finding'),fail]])
        self.run_async(Worker(self.map,lambda _:lambda **kw:runtime).once())
        result=self.run_async(self.jobs.status({'id':str(first['id'])}))
        self.assertEqual(result['failure']['category'],'timeout')
        self.assertEqual(result['checkpoint']['findings'],'Verified source A')
        self.assertIn('Partial finding',result['partial_result'])
        self.assertNotIn('private provider detail',str(result))
        self.run_async(self.jobs.retry({'id':str(first['id'])}))
        resumed=FakeRuntime([[say('Finished.')]])
        self.run_async(Worker(self.map,lambda _:lambda **kw:resumed).once())
        self.assertIn('Verified source A',resumed.sent[0])
        with self.assertRaises(ToolError):self.run_async(self.jobs.retry({'id':str(first['id'])}))

    def test_research_timeout_retries_only_once(self):
        self.start()
        async def fail(runtime):raise TimeoutError()
        for _ in range(2):
            self.run_async(Worker(self.map,lambda _:lambda **kw:FakeRuntime([[fail]])).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'failed')
        self.assertTrue(self.map.value("select (artifacts->>'automatic_retry')::boolean from assistant.jobs"))

    def test_proactive_preparation_keeps_progress_and_results_internal(self):
        first=self.start(key='proactive:prepare-later')
        async def progress(runtime):
            result=await runtime.tools['job_progress'].fn({'message':'Preparing tonight’s briefing.'})
            self.assertFalse(result['notified'])
            return say('')
        runtime=FakeRuntime([[progress,self.answer('Verified findings for tonight.')]])
        self.run_async(Worker(self.map,lambda _:lambda **kw:runtime).once())
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        self.assertEqual(self.map.value("select count(*) from assistant.attention where source='job'"),0)
        saved=self.run_async(self.jobs.status({'id':str(first['id'])}))
        self.assertEqual(saved['status'],'completed')
        self.assertEqual(saved['result'],'Verified findings for tonight.')

    def test_partial_research_continues_the_same_checklist(self):
        first=self.start()
        async def partial(runtime):
            await runtime.tools['job_plan'].fn({'items':[{'key':'a','task':'Review source A'},{'key':'b','task':'Review source B'}]})
            await runtime.tools['job_step'].fn({'key':'a','status':'done','evidence':'Source A verified.'})
            with self.assertRaises(ToolError): await runtime.tools['job_finish'].fn({'message':'All done.'})
            return say('Some work remains.')
        self.run_async(Worker(self.map,lambda _:lambda **kw:FakeRuntime([[partial]])).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'queued')
        async def finish(runtime):
            self.assertIn('Source A verified.',runtime.sent[0])
            await runtime.tools['job_step'].fn({'key':'b','status':'done','evidence':'Source B verified.'})
            await runtime.tools['job_finish'].fn({'message':'Both sources reviewed.'})
            return say('Done')
        self.run_async(Worker(self.map,lambda _:lambda **kw:FakeRuntime([[finish]])).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'completed')
        self.assertEqual(self.map.value('select count(*) from assistant.jobs'),1)

    def test_blocked_coverage_and_plain_prose_cannot_claim_completion(self):
        self.start()
        async def blocked(runtime):
            await runtime.tools['job_plan'].fn({'items':[{'key':'a','task':'Read source A'}]})
            await runtime.tools['job_step'].fn({'key':'a','status':'blocked','evidence':'The source requires access; public alternatives do not contain the information.'})
            await runtime.tools['job_finish'].fn({'message':'I need access to the source to finish.'})
            return say('Done')
        self.run_async(Worker(self.map,lambda _:lambda **kw:FakeRuntime([[blocked]])).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'failed')
        self.assertEqual(self.map.value("select artifacts->'failure'->>'category' from assistant.jobs"),'blocked')
        self.map.execute("update assistant.jobs set status='queued'")
        self.run_async(Worker(self.map,lambda _:lambda **kw:FakeRuntime([[say('All done.')]])).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'failed')

    def test_progress_is_visible_and_deduplicated_without_a_cooldown(self):
        self.start();job=self.map.row('select * from assistant.jobs');w=Worker(self.map)
        self.assertTrue(w.progress(job,'I found the original source.')['notified'])
        self.assertFalse(w.progress(job,'I found the original source.')['notified'])
        self.assertTrue(w.progress(job,'The next source is missing.')['notified'])
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),2)
        saved=self.run_async(self.jobs.status({'id':str(job['id'])}))
        self.assertEqual(saved['progress'],'The next source is missing.')

    def test_interruption_resumes_without_creating_another_job(self):
        self.start();self.map.execute("update assistant.jobs set status='running'")
        self.run_async(Worker(self.map,lambda _:lambda **kw:FakeRuntime([[self.answer('Recovered.')]])).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'completed')
        self.assertEqual(self.map.value('select count(*) from assistant.jobs'),1)

    def test_continuations_are_bounded_and_cancelled_work_stays_cancelled(self):
        self.start();w=Worker(self.map)
        for i in range(3):
            self.map.execute("update assistant.jobs set status='running'")
            job=self.map.row('select * from assistant.jobs')
            self.assertEqual(w.continue_job(job,'Continuing saved work.'),i<2)
        self.run_async(self.jobs.cancel({'id':str(job['id'])}))
        self.assertFalse(w.continue_job(job,'Must not restart.'))
        self.assertFalse(w.progress(job,'Must not announce.')['saved'])

    def test_foreground_receives_latest_requested_update_once(self):
        self.start();job=self.map.row('select * from assistant.jobs');w=Worker(self.map)
        w.progress(job,'I found the original source.')
        w.progress(job,'I verified its current details.')
        result=self.map.value("select public.assistant_client(%s,%s,'work_updates','{}')",(self.owner,self.device))
        self.assertEqual([m['content'] for m in result['messages']],['I verified its current details.'])
        again=self.map.value("select public.assistant_client(%s,%s,'work_updates','{}')",(self.owner,self.device))
        self.assertEqual(again['messages'],[])
        self.assertEqual(self.map.value('select count(*) from assistant.outbound where opened_at is not null'),2)
        history=self.map.value("select public.assistant_client(%s,%s,'bootstrap','{}')",(self.owner,self.device))['history']
        self.assertIn('I verified its current details.',[m['content'] for m in history])
        self.assertNotIn('I found the original source.',[m['content'] for m in history])

    def test_unsolicited_notices_remain_in_inbox(self):
        notice=self.map.value("insert into assistant.attention(source,source_id,title,detail,notify) values('gmail','mail-1','A message','Email details',true) returning id")
        post(self.map,'notice:'+str(notice),'Email details',{'kind':'notice','id':str(notice)})
        result=self.map.value("select public.assistant_client(%s,%s,'work_updates','{}')",(self.owner,self.device))
        self.assertEqual(result['messages'],[])
        self.assertEqual(self.map.value('select count(*) from assistant.outbound where opened_at is not null'),0)

    def test_foreground_updates_do_not_interleave_a_running_reply(self):
        self.start();job=self.map.row('select * from assistant.jobs')
        Worker(self.map).progress(job,'I verified the source.')
        self.map.value("select public.assistant_client(%s,%s,'submit',%s)",(self.owner,self.device,jsonb({'text':'Another question','client_message_id':str(uuid.uuid4())})))
        result=self.map.value("select public.assistant_client(%s,%s,'work_updates','{}')",(self.owner,self.device))
        self.assertEqual(result['messages'],[])
        self.assertEqual(self.map.value('select count(*) from assistant.outbound where opened_at is not null'),0)
