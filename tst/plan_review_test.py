from engine.plan_review import PlanReview
from engine.tools import Tools,ToolError
from tst.helpers import MapTest

class plan_review_test(MapTest):
    def setUp(self):
        super().setUp()
        self.tools=Tools(self.map,'test')
        self.specs={s.name:s for s in self.tools.specs()}
        self.review=PlanReview(self.map)
    def plan(self,item):
        result=self.run_async(self.specs['plan_add'].fn({'day':'today','item':item}))
        self.map.execute("update memory.plan_reviews set available_at=now()")
        return result
    def source(self,role='user',content='I finished the call'):
        c=self.map.value("insert into memory.conversations(agent,device,runtime) values('talk','test','codex') returning id")
        return self.map.value("insert into memory.messages(conversation_id,seq,role,content) values(%s,1,%s,%s) returning id",(c,role,content))
    def item(self,p,evidence=None,operations=None):
        return {'plan_id':p['id'],'reason':'Reviewed source evidence','evidence':evidence or [],'operations':operations or []}
    def test_coverage_is_required_and_unchanged_has_a_receipt(self):
        a=self.plan('Call');b=self.plan('Gym');rows=self.review.pending()
        with self.assertRaises(ToolError): self.run_async(self.review.commit(rows,{'items':[self.item(a)]}))
        self.run_async(self.review.commit(rows,{'items':[self.item(a),self.item(b)]}))
        self.assertFalse(self.review.pending())
        self.assertEqual(self.map.value('select count(*) from memory.plan_reviews where receipt is not null'),2)
    def test_assistant_claim_cannot_complete_a_plan(self):
        p=self.plan('Call');m=self.source('assistant')
        op={'tool':'plan_update','arguments':{'plan_id':p['id'],'version':1,'status':'done','note':'Finished'}}
        with self.assertRaises(ToolError): self.run_async(self.review.commit(self.review.pending(),{'items':[self.item(p,[m],[op])]}))
        self.assertEqual(self.map.value('select status from memory.plans where id=%s',(p['id'],)),'planned')
    def test_confirmation_updates_plan_and_preserves_history_without_requeue_loop(self):
        p=self.plan('Call');m=self.source()
        op={'tool':'plan_update','arguments':{'plan_id':p['id'],'version':1,'status':'done','note':'User confirmed completion'}}
        self.run_async(self.review.commit(self.review.pending(),{'items':[self.item(p,[m],[op])]}))
        self.assertEqual(self.map.value('select status from memory.plans where id=%s',(p['id'],)),'done')
        self.assertEqual(self.map.value('select count(*) from memory.plan_revisions'),1)
        self.assertFalse(self.review.pending())
    def test_concurrent_update_rejects_the_batch(self):
        p=self.plan('Call');rows=self.review.pending()
        self.run_async(self.specs['plan_update'].fn({'plan_id':p['id'],'version':1,'day':'tomorrow','note':'Postponed'}))
        self.map.execute('update memory.plan_reviews set available_at=now()')
        with self.assertRaises(ToolError): self.run_async(self.review.commit(rows,{'items':[self.item(p)]}))
        self.assertTrue(self.review.pending())
    def test_new_evidence_during_review_is_not_lost(self):
        p=self.plan('Call');rows=self.review.pending()
        self.map.execute('update memory.plan_reviews set requested_at=clock_timestamp()')
        self.run_async(self.review.commit(rows,{'items':[self.item(p)]}))
        self.assertTrue(self.review.pending())
    def test_new_extraction_requeues_open_plans(self):
        p=self.plan('Call');self.run_async(self.review.commit(self.review.pending(),{'items':[self.item(p)]}))
        m=self.source()
        self.map.execute('insert into memory.memory_jobs(message_id) values(%s) on conflict do nothing',(m,))
        self.map.execute("update memory.memory_jobs set status='done' where message_id=%s",(m,))
        self.map.execute('update memory.plan_reviews set available_at=now()')
        self.assertTrue(self.review.pending())
    def test_old_relevant_evidence_survives_a_busy_conversation_tail(self):
        p=self.plan('Call the dentist')
        m=self.source(content='I called the dentist and booked the appointment')
        for _ in range(25):
            self.source(content='Unrelated weather discussion')
        evidence=self.review.evidence([p])[0]['messages']
        self.assertIn(m,[r['id'] for r in evidence])
        self.assertLessEqual(len(evidence),6)
    def test_unrelated_extraction_does_not_spend_another_plan_review(self):
        p=self.plan('Call the dentist')
        self.run_async(self.review.commit(self.review.pending(),{'items':[self.item(p)]}))
        before=self.map.value('select requested_at from memory.plan_reviews where plan_id=%s',(p['id'],))
        m=self.source(content='The weather is sunny')
        self.map.execute('insert into memory.memory_jobs(message_id) values(%s) on conflict do nothing',(m,))
        self.map.execute("update memory.memory_jobs set status='done' where message_id=%s",(m,))
        self.assertEqual(before,self.map.value('select requested_at from memory.plan_reviews where plan_id=%s',(p['id'],)))
    def test_linked_structured_memory_can_resolve_a_plan_without_chat(self):
        p=self.plan('Call Cedar')
        company=self.run_async(self.specs['entity_upsert'].fn({'type':'company','name':'Cedar'}))
        person=self.run_async(self.specs['entity_upsert'].fn({'type':'person','name':'Morgan'}))
        self.run_async(self.specs['relation_register'].fn({'name':'contact','cardinality':'multi'}))
        self.run_async(self.specs['relationship_assert'].fn({'subject_id':str(company['id']),'relation':'contact','object_id':str(person['id'])}))
        self.run_async(self.specs['attribute_register'].fn({'name':'call_status','value_type':'text','cardinality':'single'}))
        fact=self.run_async(self.specs['fact_assert'].fn({'entity_id':str(person['id']),'attribute':'call_status','value':'completed'}))
        graph=self.review.graph([p])
        self.assertIn(fact['id'],[f['id'] for f in graph['facts']])
        item=self.item(p,operations=[{'tool':'plan_update','arguments':{'plan_id':p['id'],'version':1,'status':'done','entity_id':str(company['id']),'note':'Confirmed outcome in structured memory'}}])
        item['memory_evidence']=[{'kind':'assertions','id':str(fact['id'])}]
        self.run_async(self.review.commit(self.review.pending(),{'items':[item]}))
        self.assertEqual(self.map.value('select status from memory.plans where id=%s',(p['id'],)),'done')
        self.assertEqual(self.map.value('select count(*) from memory.messages'),0)

    def test_expired_memory_cannot_resolve_a_plan(self):
        p=self.plan('Call Cedar')
        entity=self.run_async(self.specs['entity_upsert'].fn({'type':'company','name':'Cedar'}))
        self.run_async(self.specs['attribute_register'].fn({'name':'call_status','value_type':'text','cardinality':'single'}))
        fact=self.run_async(self.specs['fact_assert'].fn({'entity_id':str(entity['id']),'attribute':'call_status','value':'completed'}))
        self.run_async(self.specs['fact_retract'].fn({'assertion_id':str(fact['id'])}))
        with self.assertRaises(ToolError): self.review.memory_sources([{'kind':'assertions','id':str(fact['id'])}])
    def test_changed_fact_wakes_a_plan_through_a_relationship(self):
        company=self.run_async(self.specs['entity_upsert'].fn({'type':'company','name':'Cedar'}))
        person=self.run_async(self.specs['entity_upsert'].fn({'type':'person','name':'Morgan'}))
        self.run_async(self.specs['relation_register'].fn({'name':'contact','cardinality':'multi'}))
        self.run_async(self.specs['relationship_assert'].fn({'subject_id':str(company['id']),'relation':'contact','object_id':str(person['id'])}))
        p=self.plan('Arrange appointment')
        p=self.run_async(self.specs['plan_update'].fn({'plan_id':p['id'],'version':1,'entity_id':str(company['id']),'note':'Link known company'}))
        self.map.execute('update memory.plan_reviews set available_at=now()')
        self.run_async(self.review.commit(self.review.pending(),{'items':[self.item(p)]}))
        before=self.map.value('select requested_at from memory.plan_reviews where plan_id=%s',(p['id'],))
        self.tools.message_id=self.source(content='Completed.')
        self.run_async(self.specs['attribute_register'].fn({'name':'call_status','value_type':'text','cardinality':'single'}))
        self.run_async(self.specs['fact_assert'].fn({'entity_id':str(person['id']),'attribute':'call_status','value':'completed'}))
        self.map.execute('insert into memory.memory_jobs(message_id) values(%s) on conflict do nothing',(self.tools.message_id,))
        self.map.execute("update memory.memory_jobs set status='done' where message_id=%s",(self.tools.message_id,))
        self.assertGreater(self.map.value('select requested_at from memory.plan_reviews where plan_id=%s',(p['id'],)),before)
    def test_gap_repair_and_plan_update_commit_atomically(self):
        p=self.plan('Call Cedar')
        entity=self.run_async(self.specs['entity_upsert'].fn({'type':'company','name':'Cedar'}))
        self.run_async(self.specs['attribute_register'].fn({'name':'call_status','value_type':'text','cardinality':'single'}))
        m=self.source()
        operations=[{'tool':'fact_assert','arguments':{'entity_id':str(entity['id']),'attribute':'call_status','value':'completed'}},
                    {'tool':'plan_update','arguments':{'plan_id':p['id'],'version':99,'status':'done','note':'The source confirms completion'}}]
        rows=self.review.pending()
        with self.assertRaises(ToolError): self.run_async(self.review.commit(rows,{'items':[self.item(p,[m],operations)]}))
        self.assertEqual(self.map.value('select count(*) from memory.current_assertions'),0)
        operations[1]['arguments']['version']=1
        self.run_async(self.review.commit(rows,{'items':[self.item(p,[m],operations)]}))
        self.assertEqual(self.map.value('select count(*) from memory.current_assertions'),1)
        self.assertEqual(self.map.value('select status from memory.plans where id=%s',(p['id'],)),'done')
