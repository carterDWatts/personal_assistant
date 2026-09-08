import uuid
import tempfile
from pathlib import Path
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
    def test_retry_does_not_spawn_again_and_cancel_is_terminal(self):
        first=self.start();self.assertEqual(first,self.start())
        self.run_async(self.jobs.cancel({'id':str(first['id'])}))
        self.assertFalse(self.run_async(Worker(self.map).once()))
        self.assertEqual(self.map.value('select count(*) from assistant.jobs'),1)
    def test_completion_is_one_message_with_replayable_reference(self):
        first=self.start();runtime=FakeRuntime([[say('I found the answer.')]])
        worker=Worker(self.map,lambda _:lambda **kw:runtime)
        self.assertTrue(self.run_async(worker.once()))
        self.assertFalse(self.run_async(worker.once()))
        self.assertNotIn('job_start',runtime.tools)
        self.assertNotIn('google_calendar_create_event',runtime.tools)
        self.assertEqual(self.map.value('select status from assistant.jobs'),'completed')
        row=self.map.row('select * from assistant.outbound')
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),1)
        history=self.map.value("select public.assistant_client(%s,%s,'bootstrap','{}')",(self.owner,self.device))['history']
        self.assertEqual(history[-1]['content'],'I found the answer.')
        self.assertEqual(history[-1]['payload']['reference'],row['reference'])
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
        runtime=FakeRuntime([[progress,say('Verified findings for tonight.')]])
        self.run_async(Worker(self.map,lambda _:lambda **kw:runtime).once())
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        self.assertEqual(self.map.value("select count(*) from assistant.attention where source='job'"),0)
        saved=self.run_async(self.jobs.status({'id':str(first['id'])}))
        self.assertEqual(saved['status'],'completed')
        self.assertEqual(saved['result'],'Verified findings for tonight.')
