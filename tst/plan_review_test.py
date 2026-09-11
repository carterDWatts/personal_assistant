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
        return self.run_async(self.specs['plan_add'].fn({'day':'today','item':item}))
    def source(self,role='user'):
        c=self.map.value("insert into memory.conversations(agent,device,runtime) values('talk','test','codex') returning id")
        return self.map.value("insert into memory.messages(conversation_id,seq,role,content) values(%s,1,%s,'I finished the call') returning id",(c,role))
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
        self.assertTrue(self.review.pending())
