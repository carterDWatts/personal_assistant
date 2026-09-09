import asyncio
import threading
from datetime import timedelta
from engine.conversation import Conversation
from engine.memory_worker import Worker
from engine.tools import Tools, READ_TOOLS, run
from engine import context
from tst.helpers import MapTest, FakeRuntime, say


class memory_worker_test(MapTest):
    def test_slow_write_batch_does_not_block_the_conversation_loop(self):
        async def check():
            started,release=threading.Event(),threading.Event()
            worker=Worker(self.map)
            async def blocked(*args):
                started.set()
                self.assertTrue(release.wait(3))
                return {'saved':True}
            worker._save=blocked
            task=asyncio.create_task(worker.save({}, {}, {}))
            try:
                await asyncio.wait_for(asyncio.to_thread(started.wait),1)
                self.assertFalse(task.done())
            finally:release.set()
            self.assertTrue((await task)['saved'])
        self.run_async(check())

    def job(self, text='I have a blue bicycle'):
        c=Conversation(self.map,'test','fake');s=c.open_segment('talk');c.record(s,'user',text)
        return Worker(self.map).oldest()

    def test_interrupted_extraction_remains_retryable(self):
        async def check():
            job = self.job()
            opened = asyncio.Event()
            class PausedRuntime(FakeRuntime):
                async def open(self, *args, **kwargs):
                    opened.set()
                    await asyncio.Event().wait()
            worker = Worker(self.map, lambda name: PausedRuntime([]))
            task = asyncio.create_task(worker.process(job))
            await opened.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
            self.assertEqual(self.map.value('select status from memory.memory_jobs'), 'pending')
            self.assertEqual(self.map.value('select count(*) from memory.assertions'), 0)
        self.run_async(check())

    def test_batch_commits_with_provenance_and_cannot_duplicate_on_retry(self):
        job=self.job();worker=Worker(self.map)
        tools=Tools(self.map,'test');tools.message_id=job['message_id'];tools.observed_at=job['created_at']
        specs={s.name:s for s in tools.specs() if s.name not in READ_TOOLS}
        batch={'operations':[
            {'tool':'entity_upsert','as':'bike','arguments':{'type':'vehicle','name':'Bicycle'}},
            {'tool':'attribute_register','arguments':{'name':'color','value_type':'text','cardinality':'single'}},
            {'tool':'fact_assert','arguments':{'entity_id':{'$ref':'bike'},'attribute':'color','value':'blue'}},
            {'tool':'plan_add','arguments':{'day':'tomorrow','item':'ride bicycle','status':'proposed','origin':'agent'}}]}
        self.run_async(worker.save(job,specs,batch));self.run_async(worker.save(job,specs,batch))
        self.assertEqual(self.map.value('select count(*) from memory.plans'),1)
        self.assertEqual(self.map.value('select status from memory.memory_jobs'),'done')
        self.assertEqual(self.map.value('select valid_from from memory.current_assertions'),job['created_at'])
        self.assertEqual(self.map.value("select count(*) from memory.observations where message_id=%s",(job['message_id'],)),3)

    def test_bad_batch_rolls_back_every_operation(self):
        job=self.job();tools=Tools(self.map,'test');specs={s.name:s for s in tools.specs()}
        batch={'operations':[{'tool':'entity_upsert','arguments':{'type':'vehicle','name':'Bicycle'}},
                             {'tool':'fact_assert','arguments':{'entity_id':{'$ref':'missing'},'attribute':'color','value':'blue'}}]}
        with self.assertRaises(ValueError):self.run_async(Worker(self.map).save(job,specs,batch))
        self.assertEqual(self.map.value('select count(*) from memory.entities'),0)
        self.assertEqual(self.map.value('select count(*) from memory.observations'),0)
        self.assertEqual(self.map.value('select status from memory.memory_jobs'),'pending')

    def test_failure_stays_durable_and_does_not_allow_newer_jobs_to_overtake(self):
        first=self.job();self.job('It is red now')
        class Failed(FakeRuntime):
            async def open(self,*args,**kwargs):raise RuntimeError('Subscription limit')
        worker=Worker(self.map,lambda name:Failed([]))
        self.run_async(worker.drain())
        rows=self.map.rows('select status,attempts,last_error from memory.memory_jobs order by message_id')
        self.assertEqual([r['status'] for r in rows],['error','pending'])
        self.assertEqual(rows[0]['attempts'],1)
        self.assertIn('Subscription limit',rows[0]['last_error'])
        self.assertIn('It is red now',context.snapshot(self.map))

    def test_greeting_needs_no_model_and_survives_reopening(self):
        self.job('hello')
        def forbidden(name):raise AssertionError('Greeting must not use a model')
        self.run_async(Worker(self.map,forbidden).drain())
        self.assertEqual(self.map.value('select status from memory.memory_jobs'),'done')
