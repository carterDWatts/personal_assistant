from datetime import date, datetime, timedelta
import asyncio
import json
import os
import unittest
from unittest.mock import patch
import psycopg
from engine import context
from engine.conversation import Conversation
from engine.db import jsonb
from engine.records import Records
from engine.routine import progress, spec
from engine.tools import Tools, ToolError
from tst.helpers import MapTest


class records_test(MapTest):
    def setUp(self):
        super().setUp()
        self.conv=Conversation(self.map,'test','fake')
        self.segment=self.conv.open_segment('morning')
        self.tools=Tools(self.map,'test')
        self.records=Records(self.tools)
        self.source('Breakfast was yogurt and coffee, 220 calories and 35 grams protein.')

    def source(self,text):
        self.tools.message_id=self.conv.record(self.segment,'user',text)
        return self.tools.message_id

    def meal(self,**changes):
        return {'kind':'meal','day':'2026-09-08','slot':'breakfast','status':'actual',
                'quantities':{'calories':{'value':220,'unit':'kcal','basis':'label'},'protein':{'value':35,'unit':'g','basis':'label'}},
                'details':{'foods':['yogurt','coffee']},**changes}

    def test_totals_exclude_plans_and_keep_missing_days_unknown(self):
        saved=self.run_async(self.records.save(self.meal()))
        self.source('I will have a rice bowl at lunch.')
        self.run_async(self.records.save(self.meal(slot='lunch',status='planned')))
        result=self.run_async(self.records.totals({'kind':'meal','from_day':'2026-09-08','to_day':'2026-09-09'}))
        self.assertEqual(len(result['days']),2)
        self.assertEqual([r['value'] for r in result['days']],[220,35])
        self.assertTrue(all(r['record_ids']==[saved['id']] for r in result['days']))
        self.assertTrue(all(r['day']==date(2026,9,8) for r in result['days']))

    def test_correction_replaces_totals_preserves_history_and_rejects_stale_version(self):
        old=self.source('I ate breakfast.')
        saved=self.run_async(self.records.save(self.meal()))
        corrected=self.source('Actually that was planned; I have not eaten it.')
        self.run_async(self.records.save(self.meal(id=str(saved['id']),expected_version=1,status='planned')))
        self.assertEqual(self.run_async(self.records.totals({'kind':'meal','from_day':'2026-09-08','to_day':'2026-09-08'}))['days'],[])
        revisions=self.map.rows('select snapshot from memory.record_revisions order by version')
        self.assertEqual([r['snapshot']['status'] for r in revisions],['actual','planned'])
        self.tools.message_id=old
        self.assertTrue(self.run_async(self.records.save(self.meal()))['superseded'])
        self.tools.message_id=corrected
        self.source('It happened now.')
        with self.assertRaises(ToolError): self.run_async(self.records.save(self.meal(id=str(saved['id']),expected_version=1)))
        with self.assertRaises(psycopg.Error): self.map.execute('delete from memory.record_revisions')

    def test_retries_do_not_duplicate_and_later_source_needs_explicit_correction(self):
        first=self.run_async(self.records.save(self.meal()))
        self.assertEqual(str(first['id']),self.run_async(self.records.save(self.meal()))['id'])
        self.source('Breakfast was 230 calories.')
        with self.assertRaises(ToolError):self.run_async(self.records.save(self.meal()))
        self.assertEqual(self.map.value('select count(*) from memory.records'),1)

    def test_units_and_estimates_are_not_silently_combined(self):
        for slot,unit,value,basis in [('first','g',20,'label'),('second','g',5,'estimate'),('third','oz',2,'measured')]:
            self.run_async(self.records.save(self.meal(slot=slot,quantities={'protein':{'value':value,'unit':unit,'basis':basis}})))
        days=self.run_async(self.records.totals({'kind':'meal','from_day':'2026-09-08','to_day':'2026-09-08'}))['days']
        self.assertEqual([(r['unit'],r['value'],r['estimates']) for r in days],[('g',25,1),('oz',2,0)])

    def test_database_rejects_untyped_numbers_and_foreign_source_revisions(self):
        with self.assertRaises(psycopg.Error):self.run_async(self.records.save(self.meal(quantities={'calories':{'value':'220','unit':'kcal','basis':'label'}})))
        self.assertEqual(self.map.value('select count(*) from memory.records'),0)
        self.tools.message_id=self.conv.record(self.segment,'assistant','You should eat 500 calories.')
        with self.assertRaises(ToolError):self.run_async(self.records.save(self.meal()))

    def test_three_month_query_uses_stored_rows_and_paginated_detail(self):
        for i in range(101):
            day=date(2026,5,1)+timedelta(days=i)
            self.run_async(self.records.save(self.meal(day=str(day))))
        args={'kind':'meal','from_day':'2026-05-01','to_day':'2026-08-09'}
        first=self.run_async(self.records.read(args))
        second=self.run_async(self.records.read({**args,'offset':first['next_offset']}))
        self.assertEqual((len(first['records']),len(second['records']),second['next_offset']),(100,1,None))
        self.assertEqual(len(self.run_async(self.records.totals(args))['days']),202)

    def test_record_updates_are_available_without_a_new_model_session(self):
        prepared=context.PreparedContext(self.map)
        prepared.read()
        today=str(date.today())
        self.run_async(self.records.save(self.meal(day=today)))
        self.assertIn('220',prepared.read()['records'])
        self.assertIn('yogurt',prepared.read()['records'])
        self.assertIn('yogurt',context.snapshot(self.map))

    def test_snapshot_uses_local_days_after_utc_midnight(self):
        self.run_async(self.records.save(self.meal(day='2026-09-07')))
        sections=context.snapshot_sections(self.map,now=datetime.fromisoformat('2026-09-08T23:00:00-07:00'))
        self.assertIn('yogurt',sections['records'])
        sections=context.snapshot_sections(self.map,now=datetime.fromisoformat('2026-09-09T00:01:00-07:00'))
        self.assertNotIn('yogurt',sections['records'])

    def test_morning_progress_advances_once_and_does_not_repeat_sections(self):
        tool=spec(self.tools,self.segment)
        self.run_async(tool.fn({'steps':['Calendar','Reminders','Review']}))
        self.run_async(tool.fn({'completed_step':'Calendar'}))
        self.run_async(tool.fn({'completed_step':'Calendar'}))
        self.assertEqual(progress(self.map,self.segment)['current'],'Reminders')
        with self.assertRaises(ToolError):self.run_async(tool.fn({'completed_step':'Review'}))
        with self.assertRaises(ToolError):self.run_async(tool.fn({'steps':['Restart']}))
        self.run_async(tool.fn({'completed_step':'Reminders'}))
        self.run_async(tool.fn({'completed_step':'Review'}))
        self.assertIsNone(progress(self.map,self.segment)['current'])

    def test_history_can_retrieve_yesterday_without_matching_the_word_yesterday(self):
        mid=self.map.value("insert into memory.messages(conversation_id,seq,role,content,created_at) values(%s,2,'user','Yogurt and coffee for breakfast.','2026-09-08 08:00:00-07') returning id",(self.segment,))
        self.source('What was my breakfast yesterday?')
        result=self.run_async(self.tools.conversation_history({'query':'breakfast','from_day':'2026-09-08','to_day':'2026-09-08'}))
        self.assertEqual([r['id'] for r in result],[mid])

    @unittest.skipUnless(os.environ.get('ASSISTANT_LIVE_MEMORY_TEST')=='1','Opt-in subscription test')
    def test_fresh_model_recalls_extracted_quantities_without_the_source_chat(self):
        from engine.memory_worker import Worker
        from engine.runtime.codex import CodexRuntime
        from engine import config
        async def check():
            worker=Worker(self.map,lambda _:CodexRuntime(model='gpt-5.5',effort='low'))
            job=worker.oldest()
            await worker.process(job)
            self.assertEqual(self.map.value('select status from memory.memory_jobs where message_id=%s',(job['message_id'],)),'done')
            rows=self.map.rows("select * from memory.records where status='actual'")
            self.assertTrue(rows,'Extraction must save quantities, not just mark the job done.')
            reader=CodexRuntime(model='gpt-5.5',effort='low')
            output=[];reads=[]
            try:
                await reader.open('Read the stored records. Return only a JSON object with numeric calories and protein fields for the requested day. Do not guess.',self.records.specs()[1:])
                async def consume():
                    async for event in reader.send(f"What were my breakfast calories and protein on {rows[0]['day']}?"):
                        if event.kind=='assistant_text':output.append(event.text)
                        if event.kind=='tool_use':reads.append(event.name)
                await asyncio.wait_for(consume(),60)
            finally:await reader.close()
            self.assertTrue(set(reads)&{'records_read','records_totals'})
            self.assertEqual(json.loads(output[-1].strip().removeprefix('```json').removesuffix('```')),
                             {'calories':220,'protein':35})
        with patch.object(config,'ENV','test'):
            self.run_async(check())
