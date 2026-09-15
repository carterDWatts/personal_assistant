import json
import uuid

from engine.db import jsonb
from engine.memory_context import MemoryContext
from engine.memory_worker import Worker
from engine.tools import Tools
from tst.helpers import MapTest, FakeRuntime, call


class memory_context_test(MapTest):
    def put(self, recording=None, index=0, text='A meeting excerpt.', **changes):
        args = dict(id=str(uuid.uuid4()), title='Meeting', kind='current', runtime='codex',
                    source='meeting', part=0, parts=1, text=text)
        if recording is not None:
            args.update(recording_id=str(recording), recording_index=index)
        args.update(changes)
        self.map.value('select memory.import_part(%s)', (jsonb(args),))
        return args

    def job(self, args):
        return self.map.row('select j.*,m.content,m.created_at,m.conversation_id,m.payload,c.runtime'
                            ' from memory.import_parts p join memory.messages m on m.id=p.message_id'
                            ' join memory.memory_jobs j on j.message_id=m.id'
                            ' join memory.conversations c on c.id=m.conversation_id where p.import_id=%s', (args['id'],))

    def entity(self, name):
        return self.run_async(Tools(self.map, 'test').entity_upsert({'name':name, 'type':'organization'}))['id']

    def test_recording_retries_preserve_identity_and_cannot_mix_batches(self):
        group = uuid.uuid4()
        first = self.put(group)
        self.map.value('select memory.import_part(%s)', (jsonb(first),))
        self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'),1)
        for changes in ({'recording_index':1}, {'recording_id':str(uuid.uuid4())}):
            with self.assertRaises(Exception):
                self.map.value('select memory.import_part(%s)', (jsonb(first | changes),))
        with self.assertRaises(Exception): self.put(group)
        with self.assertRaises(Exception): self.put(group, 1, kind='history')
        self.put(group, 1)
        self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'),2)

    def test_group_requires_meeting_source_and_complete_coordinates(self):
        for changes in ({'source':None}, {'recording_index':None}, {'recording_index':-1}, {'parts':2}):
            with self.assertRaises(Exception): self.put(uuid.uuid4(), **changes)
        with self.assertRaises(Exception): self.put(recording_index=0)
        self.assertEqual(self.map.value('select count(*) from memory.imports'),0)

    def test_old_client_retry_can_add_grouping_without_reextracting(self):
        first = self.put()
        group = str(uuid.uuid4())
        self.map.value('select memory.import_part(%s)', (jsonb(first | {'recording_id':group,'recording_index':0}),))
        self.map.value('select memory.import_part(%s)', (jsonb(first),))
        self.assertEqual(str(self.map.value('select recording_id from memory.imports')),group)
        self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'),1)

    def test_recording_context_links_adjacent_chunks_but_not_other_meetings(self):
        group = uuid.uuid4()
        self.put(group, 0, 'I represent Northstar. We are discussing the engineering role.')
        middle = self.put(group, 1, 'The assessment takes three hours.')
        self.put(group, 2, 'You have one week to complete it.')
        self.put(uuid.uuid4(), 0, 'Unrelated confidential meeting.')
        company = self.entity('Northstar')
        context = MemoryContext(self.map, self.job(middle), {})
        initial = json.loads(context.initial())
        self.assertEqual([r['position'] for r in initial['source_excerpts']],[0,2])
        self.assertIn(str(company),[r['id'] for r in initial['known_entities']])
        self.assertNotIn('Unrelated confidential',context.initial())
        page = self.run_async(context.source_parts({'start':1}))
        self.assertEqual([r['position'] for r in page['parts']],[1,2])

    def test_lookup_pages_every_fact_without_expanding_initial_context(self):
        args = self.put(text='Northstar has an assessment.')
        company = self.entity('Northstar')
        tools = Tools(self.map, 'test')
        self.run_async(tools.attribute_register({'name':'detail','value_type':'text','cardinality':'multi'}))
        for n in range(19):
            self.run_async(tools.fact_assert({'entity_id':str(company),'attribute':'detail','value':f'Detail {n}'}))
        context = MemoryContext(self.map,self.job(args),{})
        original = context.initial()
        unrelated = self.entity('Elsewhere')
        self.run_async(tools.fact_assert({'entity_id':str(unrelated),'attribute':'detail','value':'UNRELATED '*10000}))
        self.assertEqual(context.initial(),original)
        found, offset = set(), 0
        while offset is not None:
            page = self.run_async(context.lookup({'entity_id':str(company),'offset':offset}))
            self.assertLessEqual(len(page['facts']),8)
            found.update(str(r['id']) for r in page['facts'])
            offset = page['next_offset']
        self.assertEqual(len(found),19)
        self.assertEqual(len(json.loads(original)['current_facts_excerpt']),16)

    def test_worker_records_actual_effect_and_external_provenance(self):
        group = uuid.uuid4()
        entity = self.entity('Northstar')
        tools = Tools(self.map,'test')
        self.run_async(tools.attribute_register({'name':'color','value_type':'text','cardinality':'single'}))
        for index, (value,effect) in enumerate([('blue','created'),('blue','confirmed'),('red','changed')]):
            args = self.put(group,index,f'The color is {value}.')
            job = self.job(args)
            tools.message_id,tools.observed_at = job['message_id'],job['created_at']
            worker = Worker(self.map)
            self.run_async(worker.save(job,{s.name:s for s in tools.specs()}, {'operations':[
                {'tool':'fact_assert','arguments':{'entity_id':str(entity),'attribute':'color','value':value,'level':'stated'}}]}))
            receipt = self.map.value('select receipt from memory.memory_jobs where message_id=%s',(job['message_id'],))
            result = receipt['outcomes'][0]
            self.assertEqual(result['effect'],effect)
            self.assertEqual(result['arguments']['level'],'synced')
            self.assertEqual(result['after'][0]['level'],'synced')
            self.assertIsNotNone(result['record_id'])
        self.assertEqual(self.map.value('select count(*) from memory.assertion_sources'),3)

    def test_historical_receipt_identifies_created_closed_fact(self):
        args = self.put(text='It was blue in 2020.',kind='history')
        job = self.job(args)
        entity = self.entity('Northstar')
        tools = Tools(self.map,'test')
        tools.message_id,tools.observed_at = job['message_id'],job['created_at']
        self.run_async(tools.attribute_register({'name':'color','value_type':'text','cardinality':'single'}))
        self.run_async(Worker(self.map).save(job,{s.name:s for s in tools.specs()}, {'operations':[
            {'tool':'fact_assert','arguments':{'entity_id':str(entity),'attribute':'color','value':'blue',
              'valid_from':'2020-01-01T00:00:00Z','valid_to':'2021-01-01T00:00:00Z'}}]}))
        receipt = self.map.value('select receipt from memory.memory_jobs')
        self.assertEqual(receipt['outcomes'][0]['effect'],'created')
        self.assertEqual(self.map.value('select count(*) from memory.current_assertions'),0)

    def test_worker_saves_audit_metrics_and_keeps_rules_in_stable_instructions(self):
        args = self.put()
        self.map.execute("insert into memory.rules(kind,text,created_by) values('mandate','Keep exact measured quantities.','test')")
        runtime = FakeRuntime([[call('memory_source',start=0),call('save_memory',operations=[],reason='Only filler.')]])
        self.run_async(Worker(self.map,lambda _:runtime).process(self.job(args)))
        row = self.map.row('select status,metrics,last_error from memory.memory_jobs')
        self.assertEqual(row['status'],'done',row['last_error'])
        self.assertEqual(row['metrics']['read_calls'],1)
        self.assertGreater(row['metrics']['read_chars'],0)
        self.assertGreater(row['metrics']['context_chars'],0)
        self.assertIn('Keep exact measured quantities.',runtime.opened['system_prompt'])
        self.assertNotIn('map_search',runtime.tools)
        self.assertIn('memory_lookup',runtime.tools)
