import os
import uuid
from unittest.mock import Mock, patch
from engine.developer import editable, DraftWorkspace, ReviewAccess, enqueue
from engine.development import Development
from engine.jobs import Worker
from engine.tools import Tools, ToolError
from engine.db import jsonb
from tst.helpers import MapTest, FakeRuntime, say

class developer_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner=uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)',(self.owner,))
        self.map.execute("update assistant.development_review set cursor=0,next_review_at=now()-interval '1 hour'")
        self.env=patch.dict(os.environ,{'ASSISTANT_DEVELOPMENT_REVIEW':'1','ASSISTANT_DEVELOPER_OWNER':str(self.owner),'ASSISTANT_DEVELOPER_REPO':'example/assistant','ASSISTANT_DEVELOPER_PROJECT':'abcdefghijklmnopqrst'})
        self.env.start();self.addCleanup(self.env.stop)
        segment=self.map.value("insert into memory.conversations(agent,device,runtime) values('test','test','codex') returning id")
        self.message=self.map.value("insert into memory.messages(conversation_id,seq,role,content,created_at) values(%s,1,'user','The app lost my draft.',now()-interval '3 minutes') returning id",(segment,))

    def test_scheduler_is_opt_in_deduplicated_and_does_not_run_without_new_chat(self):
        with patch.dict(os.environ,{'ASSISTANT_DEVELOPMENT_REVIEW':'0'}):self.assertFalse(enqueue(self.map))
        self.assertTrue(enqueue(self.map));self.assertFalse(enqueue(self.map))
        job=self.map.row('select * from assistant.jobs')
        self.assertEqual(job['model'],'gpt-6-astra')
        self.assertEqual(job['runtime'],'codex')
        self.map.execute("update assistant.jobs set status='completed'")
        self.map.execute("update assistant.development_review set next_review_at=now()-interval '1 hour'")
        self.assertFalse(enqueue(self.map))

    def test_protected_paths_and_publication_are_enforced(self):
        for path in ['prompts/persona.md','identity.json','engine/../prompts/persona.md','engine/developer.py','supabase/migrations/new.sql','engine/config.py','engine/memory_worker.py','engine/integrations/email.py','shared/integrations.json']:
            with self.assertRaises(ToolError):editable(path)
            with self.assertRaises(ToolError):self.run_async(DraftWorkspace().write({'path':path,'content':'changed'}))
        editable('ios/Assistant/Views.swift')
        self.assertTrue(enqueue(self.map));job=self.map.row('select * from assistant.jobs')
        access=ReviewAccess(Tools(self.map,'test'),job)
        names={s.name for s in access.review_specs()}
        self.assertEqual(names,{'development_file','development_publish','development_status'})
        with self.assertRaises(ToolError):self.run_async(access.publish({'files':{'prompts/persona.md':'changed'}}))
        dev=Development(Tools(self.map,'test'));dev.github=Mock(return_value={'head':{'repo':{'full_name':'example/assistant'},'ref':'development/test','sha':'a'*40},'base':{'ref':'main'}})
        with self.assertRaises(ToolError):self.run_async(dev.merge({'number':1,'sha':'a'*40}))
        self.assertEqual(dev.github.call_count,1)

    def test_no_findings_stays_quiet_and_agent_has_no_write_or_spawn_tools(self):
        enqueue(self.map)
        runtime=FakeRuntime([[say('NO_CHANGE')]])
        self.assertTrue(self.run_async(Worker(self.map,lambda _:lambda **kw:runtime).once()))
        for name in ('development_merge','development_database_migrate','development_database_read','fact_assert','preference_save','job_start','google_mail_draft'):
            self.assertNotIn(name,runtime.tools)
        self.assertEqual(self.map.value('select count(*) from assistant.outbound'),0)
        self.assertEqual(self.map.value('select status from assistant.jobs'),'completed')
        self.assertEqual(self.map.value('select count(*) from memory.rules'),0)
