from engine.tools import Tools, ToolError
from engine.reconciliation import Reconciliation
from tst.helpers import MapTest

class reconciliation_test(MapTest):
    def setUp(self):
        super().setUp()
        self.tools=Tools(self.map,'test')
        self.r=Reconciliation(self.tools)
        self.entity=self.run_async(self.tools.entity_upsert({'type':'person','name':'Example'}))['id']
        for name in ('a','b','derived'):
            self.run_async(self.tools.attribute_register({'name':name,'value_type':'text','cardinality':'single'}))
        self.a=self.run_async(self.tools.fact_assert({'entity_id':str(self.entity),'attribute':'a','value':'first'}))
        self.b=self.run_async(self.tools.fact_assert({'entity_id':str(self.entity),'attribute':'b','value':'second'}))

    def inference(self):
        return self.run_async(self.r.infer({'tool':'fact_assert','arguments':{'entity_id':str(self.entity),'attribute':'derived','value':'conclusion'},'evidence':[{'kind':'assertions','id':str(x['id'])} for x in (self.a,self.b)],'rationale':'Test inference supported by two records.'}))

    def user(self,text):
        c=self.map.value("insert into memory.conversations(agent,device,runtime) values('test','test','codex') returning id")
        self.tools.message_id=self.map.value("insert into memory.messages(conversation_id,seq,role,content) values(%s,1,'user',%s) returning id",(c,text))

    def test_derivation_is_inferred_and_invalidated_when_evidence_changes(self):
        derived=self.inference()
        self.assertEqual(derived['level'],'inferred')
        self.assertEqual(self.map.value('select count(*) from memory.derivations'),2)
        self.run_async(self.tools.fact_deprecate({'assertion_id':str(self.a['id']),'statement':'This was never true.'}))
        self.assertFalse(self.map.value('select exists(select 1 from memory.current_assertions where id=%s)',(derived['id'],)))
        self.assertIn('Supporting',self.map.value('select resolution_reason from memory.assertions where id=%s',(derived['id'],)))

    def test_inference_cannot_replace_existing_truth(self):
        self.inference()
        with self.assertRaises(ToolError): self.inference()

    def test_clarification_is_atomic_and_preserves_correction(self):
        self.user('The first claim was never true.')
        q=self.run_async(self.tools.question_add({'text':'Was this true?'}))['id']
        ops=[{'tool':'fact_deprecate','arguments':{'assertion_id':str(self.a['id'])}}]
        with self.assertRaises(ToolError):
            self.run_async(self.r.resolve({'question_id':q,'operations':ops+[{'tool':'fact_confirm','arguments':{'assertion_id':'00000000-0000-0000-0000-000000000000'}}]}))
        self.assertIsNone(self.map.value('select closed_at from memory.questions where id=%s',(q,)))
        self.assertEqual(self.map.value('select rank from memory.assertions where id=%s',(self.a['id'],)),'normal')
        self.run_async(self.r.resolve({'question_id':q,'operations':ops}))
        self.assertEqual(self.map.value('select resolution_reason from memory.assertions where id=%s',(self.a['id'],)),'The first claim was never true.')
        self.assertIsNotNone(self.map.value('select closed_at from memory.questions where id=%s',(q,)))

    def test_preferences_replace_immediately_and_require_user(self):
        with self.assertRaises(ToolError): self.run_async(self.r.preference({'text':'No news.'}))
        self.user('No news in the morning.')
        old=self.run_async(self.r.preference({'text':'No news in the morning.'}))
        self.user('Actually include science news.')
        self.run_async(self.r.preference({'text':'Include science news in the morning.','replaces':[old['id']]}))
        self.assertEqual(self.map.value("select count(*) from memory.rules where status='active'"),1)
        self.assertEqual(self.map.value('select status from memory.rules where id=%s',(old['id'],)),'retired')

    def test_rejected_inference_cannot_be_reintroduced(self):
        derived=self.inference()
        self.run_async(self.tools.fact_deprecate({'assertion_id':derived['id'],'statement':'That conclusion was never true.'}))
        with self.assertRaises(ToolError): self.inference()

    def test_direct_correction_does_not_need_queued_question(self):
        self.user('That was never true.')
        self.run_async(self.r.resolve({'operations':[{'tool':'fact_deprecate','arguments':{'assertion_id':str(self.a['id'])}}]}))
        self.assertEqual(self.map.value('select rank from memory.assertions where id=%s',(self.a['id'],)),'deprecated')
