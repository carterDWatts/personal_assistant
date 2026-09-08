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

    def test_ended_fact_preserves_history_and_explanation(self):
        from datetime import datetime,timezone,timedelta
        start=(datetime.now(timezone.utc)-timedelta(days=10)).isoformat()
        fact=self.run_async(self.tools.fact_assert({'entity_id':str(self.entity),'attribute':'derived','value':'old','valid_from':start}))
        self.user('That was true until yesterday; I moved.')
        end=(datetime.now(timezone.utc)-timedelta(days=1)).isoformat()
        self.run_async(self.r.resolve({'operations':[{'tool':'fact_retract','arguments':{'assertion_id':str(fact['id']),'valid_to':end}}]}))
        row=self.map.row('select * from memory.assertions where id=%s',(fact['id'],))
        self.assertNotEqual(row['rank'],'deprecated')
        self.assertIsNotNone(row['valid'].upper)
        self.assertIn('moved',row['resolution_reason'])

    def test_nightly_relationship_creation_has_evidence(self):
        other=self.run_async(self.tools.entity_upsert({'type':'project','name':'Example project'}))['id']
        self.run_async(self.tools.relation_register({'name':'interested_in','cardinality':'multi'}))
        row=self.run_async(self.r.infer({'tool':'relationship_assert','arguments':{'subject_id':str(self.entity),'relation':'interested_in','object_id':str(other)},'evidence':[{'kind':'assertions','id':str(x['id'])} for x in (self.a,self.b)],'rationale':'Both records support interest.'}))
        self.assertEqual(row['level'],'inferred')
        self.assertEqual(self.map.value('select count(*) from memory.derivations where relationship_id=%s',(row['id'],)),2)
        self.run_async(self.tools.fact_deprecate({'assertion_id':str(self.b['id']),'statement':'Wrong.'}))
        self.assertEqual(self.map.value('select rank from memory.relationships where id=%s',(row['id'],)),'deprecated')

    def test_linked_question_cannot_close_without_correction(self):
        q=self.run_async(self.tools.question_add({'text':'Was this ever true?','ref_table':'assertions','ref_id':str(self.a['id'])}))['id']
        with self.assertRaises(ToolError): self.run_async(self.tools.question_update({'question_id':q,'action':'answered','answer':'No'}))

    def test_replacement_retains_the_users_explanation(self):
        self.user('It changed to new because I moved.')
        self.run_async(self.r.resolve({'operations':[{'tool':'fact_assert','arguments':{'entity_id':str(self.entity),'attribute':'a','value':'new'}}]}))
        row=self.map.row('select rank,valid,resolution_reason from memory.assertions where id=%s',(self.a['id'],))
        self.assertNotEqual(row['rank'],'deprecated')
        self.assertIsNotNone(row['valid'].upper)
        self.assertIn('because I moved',row['resolution_reason'])

    def test_archive_hides_irrelevant_memory_without_calling_it_false(self):
        derived=self.inference()
        self.user('This subject does not matter. Stop keeping it in active memory.')
        self.run_async(self.r.archive({'records':[{'kind':'assertions','id':str(self.a['id'])}]}))
        self.assertEqual(self.map.value('select rank from memory.assertions where id=%s',(self.a['id'],)),'normal')
        self.assertFalse(self.map.value('select exists(select 1 from memory.current_assertions where id=%s)',(self.a['id'],)))
        self.assertFalse(self.map.value('select exists(select 1 from memory.current_assertions where id=%s)',(derived['id'],)))
        with self.assertRaises(ToolError): self.inference()
        self.run_async(self.r.archive({'records':[{'kind':'assertions','id':str(self.a['id'])}],'restore':True}))
        self.assertTrue(self.map.value('select exists(select 1 from memory.current_assertions where id=%s)',(self.a['id'],)))
