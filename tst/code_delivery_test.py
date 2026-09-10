import asyncio
import base64
import os
import tempfile
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import AsyncMock, Mock, patch

from engine.code_delivery import Delivery, can_ship
from engine.developer import DraftWorkspace, editable
from engine.development import Development
from engine.jobs import Worker, Jobs
from engine.tools import Tools, ToolError, ToolSpec, _obj
from engine.workspace import Workspace
from engine.db import jsonb
from tst.helpers import FakeRuntime, say, MapTest


class workspace_edit_test(TestCase):
    def test_large_file_edit_keeps_tail_and_recovers_from_checkpoint(self):
        source = 'header\n' + 'x' * 25000 + '\nlet marker = 1\n' + 'tail' * 6000
        dev = Mock(status=AsyncMock(return_value={'base_sha':'a'*40}))
        dev.github.side_effect = lambda path: ({'tree':[{'path':'ios/Assistant/Views.swift','type':'blob'}]} if path.startswith('git/trees/') else
                                               {'encoding':'base64','content':base64.b64encode(source.encode()).decode()})
        async def run():
            with tempfile.TemporaryDirectory() as root:
                w = Workspace(Path(root)); await w.checkout(dev)
                first = await w.read({'path':'ios/Assistant/Views.swift'})
                self.assertEqual(first['next_offset'],20000)
                self.assertNotIn('marker',first['text'])
                second = await w.read({'path':'ios/Assistant/Views.swift','offset':first['next_offset']})
                self.assertIn('marker',second['text'])
                await w.edit({'path':'ios/Assistant/Views.swift','old_text':'let marker = 1','new_text':'let marker = 2'})
                recovered = Workspace(Path(root)); await recovered.checkout(dev,w.checkpoint())
                self.assertEqual(recovered.files['ios/Assistant/Views.swift'],source.replace('marker = 1','marker = 2'))
                self.assertEqual(recovered.patch(),w.patch())
                with self.assertRaises(ToolError):
                    await w.edit({'path':'ios/Assistant/Views.swift','old_text':'tail','new_text':'oops'})
                dev.status.return_value={'base_sha':'b'*40}
                with self.assertRaises(ToolError):await recovered.checkout(dev,w.checkpoint())
        asyncio.run(run())

    def test_passive_reviewer_cannot_edit_its_delivery_controls(self):
        for path in ('engine/code_delivery.py','scripts/release-ios.py','scripts/testflight.py'):
            with self.assertRaises(ToolError):editable(path)
        with tempfile.TemporaryDirectory() as root:
            (Path(root)/'prompts').mkdir();(Path(root)/'prompts/persona.md').write_text('Protected identity')
            w=DraftWorkspace(Path(root))
            with self.assertRaises(ToolError):asyncio.run(w.edit({'path':'prompts/persona.md','old_text':'identity','new_text':'changed'}))
            self.assertEqual(w.patch(),'')

    def test_shipping_scope_excludes_server_controls_and_project_scripts(self):
        self.assertTrue(can_ship(['ios/Assistant/Views.swift','tst/example_test.py']))
        for extra in ('engine/jobs.py','.github/workflows/test.yml','scripts/test.sh','prompts/persona.md','ios/Assistant.xcodeproj/project.pbxproj'):
            self.assertFalse(can_ship(['ios/Assistant/Views.swift',extra]))
        self.assertFalse(can_ship(['tst/example_test.py']))

    def test_publication_recovers_existing_pr_without_new_commit(self):
        dev=Development(SimpleNamespace(map=Mock()))
        dev.scope=Mock(return_value=('example/assistant','project'));dev.publication_key='job-id'
        dev.github=Mock(return_value=[{'number':7,'html_url':'https://github.com/example/assistant/pull/7','head':{'sha':'a'*40}}])
        result=asyncio.run(dev.publish({'files':{'ios/Assistant/Views.swift':'code'},'base_sha':'old'}))
        self.assertEqual(result['number'],7);self.assertEqual(dev.github.call_count,1)


class delivery_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner=uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        c=self.map.value("insert into memory.conversations(agent,device,runtime) values('test','test','codex') returning id")
        self.tools=Tools(self.map,'test')
        self.tools.message_id=self.map.value("insert into memory.messages(conversation_id,seq,role,content) values(%s,1,'user','Show the build in Settings') returning id",(c,))
        self.jobs=Jobs(self.tools)
        self.env=patch.dict(os.environ,{'ASSISTANT_DEVELOPMENT_AUTOSHIP':'1'})
        self.env.start();self.addCleanup(self.env.stop)

    def tearDown(self):
        if getattr(self,'map',None):self.map.execute('truncate assistant.owner,assistant.host cascade')
        super().tearDown()

    def start(self,**extra):
        return self.run_async(self.jobs.start({'key':'test','task':'Show the build in Settings','kind':'code',**extra}))

    def delivery(self):
        self.start(kind='code')
        self.map.execute("update assistant.jobs set status='running'")
        job=self.map.row('select * from assistant.jobs')
        d=Delivery(self.tools,job)
        d.dev=Mock(publish=AsyncMock(return_value={'number':7,'url':'https://example/pr/7','sha':'a'*40}),
                   status=AsyncMock(return_value={'checks':[]}),merge=AsyncMock(return_value={'merged':True,'sha':'b'*40}))
        return d

    def submitted(self):
        d=self.delivery()
        w=SimpleNamespace(files={'ios/Assistant/Views.swift':'new'},original={'ios/Assistant/Views.swift':'old'},base_sha='a'*40,checkpoint=lambda:{})
        self.run_async(d.submit(w,{'title':'Show the app version.','description':'Settings displays the installed build.'}))
        return d

    def test_no_patch_cannot_claim_completion(self):
        d=self.delivery()
        w=SimpleNamespace(files={},original={},base_sha='a'*40)
        with self.assertRaises(ToolError):self.run_async(d.submit(w,{'title':'Change'}))
        d.dev.publish.assert_not_called()

    def test_ci_wait_merge_release_and_one_notification_without_model(self):
        d=self.submitted()
        pr={'head':{'sha':'a'*40},'state':'open','merged':False}
        d.dev.github=Mock(return_value=pr)
        worker=Worker(self.map,Mock(side_effect=AssertionError('Delivery must not start a model')))
        self.run_async(d.advance(worker.finish));d.dev.merge.assert_not_called()
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        d.dev.status.return_value={'checks':[{'name':n,'status':'completed','conclusion':'success'} for n in ('assistant-tests','assistant-apps')]}
        d.dev.github.side_effect=[pr,[{'filename':'ios/Assistant/Views.swift'}],{'workflow_runs':[]}]
        self.run_async(d.advance(worker.finish))
        self.assertEqual(self.map.value("select artifacts->'delivery'->>'phase' from assistant.jobs"),'release')
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        d.dev.github.side_effect=[pr,{'workflow_runs':[{'status':'completed','conclusion':'success'}]},
                                   {'body':'Version 0.1, build 1011.','html_url':'https://example/release'}]
        self.map.execute("update assistant.jobs set status='queued',artifacts=jsonb_set(artifacts,'{delivery,next_check}',to_jsonb('2000-01-01'::text))")
        with patch('engine.code_delivery.Development',return_value=d.dev):
            self.run_async(worker.once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'completed')
        self.assertIn('1011',self.map.value('select result from assistant.jobs'))
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),1)
        self.assertFalse(self.run_async(worker.once()))

    def test_failed_check_never_merges(self):
        d=self.submitted();d.dev.github=Mock(return_value={'head':{'sha':'a'*40},'state':'open'})
        d.dev.status.return_value={'checks':[{'name':'assistant-apps','status':'completed','conclusion':'failure'}]}
        self.run_async(d.advance(Worker(self.map).finish))
        self.assertEqual(self.map.value('select status from assistant.jobs'),'failed')
        d.dev.merge.assert_not_called()
        self.run_async(self.jobs.retry({'id':str(d.job['id'])}))
        state=self.map.value("select artifacts->'delivery' from assistant.jobs")
        self.assertEqual(state['phase'],'checks')
        self.assertNotIn('outcome',state)

    def test_changed_revision_cannot_ship(self):
        d=self.submitted();d.dev.github=Mock(return_value={'head':{'sha':'c'*40},'state':'open'})
        self.run_async(d.advance(Worker(self.map).finish))
        self.assertEqual(self.map.value('select status from assistant.jobs'),'failed')
        d.dev.merge.assert_not_called()

    def test_restart_resumes_delivery_without_model(self):
        d=self.submitted()
        self.map.execute("update assistant.jobs set artifacts=jsonb_set(artifacts,'{delivery,next_check}',to_jsonb('2000-01-01'::text))")
        d.dev.github=Mock(return_value={'head':{'sha':'a'*40},'state':'open'})
        factory=Mock(side_effect=AssertionError('No model during delivery'))
        with patch('engine.code_delivery.Development',return_value=d.dev):
            self.run_async(Worker(self.map,factory).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'queued')
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        factory.assert_not_called()

    def test_disabled_shipping_stops_at_review(self):
        d=self.submitted()
        with patch.dict(os.environ,{'ASSISTANT_DEVELOPMENT_AUTOSHIP':'0'}):self.run_async(d.advance(Worker(self.map).finish))
        d.dev.github.assert_not_called();d.dev.merge.assert_not_called()
        self.assertIn('not enabled',self.map.value('select result from assistant.jobs'))

    def test_code_prose_without_submission_fails(self):
        self.start(kind='code')
        runtime=FakeRuntime([[say('Here is the patch you should apply.')]])
        dev=Mock(specs=Mock(return_value=[ToolSpec('development_status','status',_obj({},[]),AsyncMock())]),status=AsyncMock(return_value={'base_sha':'a'*40}),github=Mock(return_value={'tree':[]}))
        with patch('engine.code_delivery.Development',return_value=dev):
            self.run_async(Worker(self.map,lambda _:lambda **kw:runtime).once())
        self.assertEqual(self.map.value('select status from assistant.jobs'),'failed')
        self.assertIn('workspace_edit',runtime.tools)
        self.assertIn('workspace_submit',runtime.tools)
        self.assertNotIn('development_publish',runtime.tools)
