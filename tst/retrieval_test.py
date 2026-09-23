import json
import uuid
from engine.db import jsonb, dumps
from engine.tools import Tools
from engine.retrieval import retrieve, sources, block
from engine import engine
from tst.helpers import MapTest, FakeRuntime, FakeTerminal, say


class retrieval_test(MapTest):
    def fact(self, name, attribute, value, message_id=None):
        tools=Tools(self.map,'test')
        tools.message_id=message_id
        entity=self.run_async(tools.entity_upsert({'type':'organization','name':name}))
        self.run_async(tools.attribute_register({'name':attribute,'value_type':'json','cardinality':'single'}))
        return self.run_async(tools.fact_assert({'entity_id':str(entity['id']),'attribute':attribute,'value':value}))

    def source(self, text, title='Meeting', recording=None, index=0, kind='current'):
        args=dict(id=str(uuid.uuid4()),title=title,kind=kind,runtime='codex',source='meeting',part=0,parts=1,text=text)
        if recording:args.update(recording_id=str(recording),recording_index=index)
        self.map.value('select memory.import_part(%s)',(jsonb(args),))
        return self.map.row('select import_id,message_id from memory.import_parts where import_id=%s',(args['id'],))

    def test_company_identity_is_retrieved_beyond_global_snapshot(self):
        self.map.execute("insert into memory.attributes(name,value_type,cardinality,importance,created_by) values('description','json','single',3,'test')")
        for n in range(180):self.fact(f'AAA unrelated {n}','description','Unrelated priority item')
        self.fact('Basis','company_profile',{'product':'AI agents for accounting','location':'NYC'})
        from engine.context import facts_block
        self.assertNotIn('AI agents for accounting',facts_block(self.map))
        rt=FakeRuntime([[say('An accounting company.')]])
        self.run_async(engine.run('talk',self.map,rt,FakeTerminal(['Tell me about Basis before the call']),'mac'))
        self.assertIn('AI agents for accounting',rt.sent[0])
        self.assertIn('Relevant memory for this turn',rt.sent[0])

    def test_followup_retains_topic_and_explicit_switch_prioritizes_new_entity(self):
        self.fact('Motorcycle safety class','provider',{'name':'WMST','required_gear':'helmet and boots'})
        self.fact('Basis','company_profile','Accounting agents in NYC')
        r=retrieve(self.map,'They say on the website, can you check?','I need gear for motorcycle school.')
        self.assertIn('WMST',dumps(r))
        r=retrieve(self.map,'Tell me about Basis','I need gear for motorcycle school.')
        self.assertEqual(r['facts'][0]['entity_name'],'Basis')

    def test_provenance_finds_misrecognized_name_and_neighboring_recording(self):
        recording=uuid.uuid4()
        first=self.source('I work at AfterCar.',recording=recording)
        second=self.source('The work trial is in person.',recording=recording,index=1)
        f=self.fact('AfterQuery','company_profile','Data company',first['message_id'])
        self.source('Unrelated private meeting',title='Other')
        result=self.run_async(Tools(self.map,'test').context_import_search({'query':'AfterQuery'}))
        self.assertEqual({r['message_id'] for r in result},{first['message_id'],second['message_id']})
        self.assertIn('AfterCar',dumps(retrieve(self.map,'AfterQuery',prior='')))
        self.assertEqual(len(sources(self.map,import_id=str(first['import_id']))),2)

    def test_legacy_batches_and_pagination_preserve_source_status(self):
        first=self.source('after query accounting',kind='history')
        for n in range(6):self.source(f'Other detail {n}',kind='history')
        f=self.fact('AfterQuery','description','Company details',first['message_id'])
        tools=Tools(self.map,'test')
        one=self.run_async(tools.context_import_search({'entity_id':str(f['entity_id'])}))
        two=self.run_async(tools.context_import_search({'entity_id':str(f['entity_id']),'offset':5}))
        self.assertEqual(len(one),5)
        self.assertEqual(len(two),2)
        self.assertFalse({r['message_id'] for r in one}&{r['message_id'] for r in two})
        self.assertTrue(all(r['kind']=='history' and r['extraction_status']=='pending' for r in one))

    def test_current_state_supersedes_old_facts_and_output_is_bounded(self):
        self.fact('Strala','recruiting_status','Interview scheduled')
        self.fact('Strala','recruiting_status','Interview completed, invited to technical round')
        for n in range(25):self.fact('Strala',f'detail_{n}','x'*15000)
        text=block(self.map,'Strala interview',prior='')
        self.assertIn('Interview completed',text)
        self.assertNotIn('Interview scheduled',text)
        self.assertLess(len(text),24500)

    def test_reminder_receives_completed_interview_evidence(self):
        from engine.reminder_message import compose
        from tst.helpers import call
        from datetime import datetime, timedelta
        self.fact('Strala','recruiting_status','Interview completed; invited to the technical round')
        rt=FakeRuntime([[call('withhold_reminder',reason='Interview already happened')]])
        now=datetime.now().astimezone()
        reminder={'title':'Attend Strala interview','context':'Initial screen','timezone':'America/Los_Angeles',
                  'window_start':now-timedelta(days=1),'window_end':now-timedelta(hours=23)}
        self.assertIsNone(self.run_async(compose(self.map,reminder,factory=lambda _:rt)))
        self.assertIn('Interview completed',rt.sent[0])

    def test_topic_can_be_recovered_from_prior_conversation_and_clear_is_respected(self):
        from engine.conversation import Conversation
        conv=Conversation(self.map,'mac','fake')
        segment=conv.open_segment('talk')
        conv.record(segment,'user','WMST is the motorcycle school I chose.')
        r=retrieve(self.map,'Which motorcycle school did I choose?',prior='')
        self.assertIn('WMST',dumps(r['conversation_evidence']))
        conv.record(segment,'system','Clear',{'event':'chat_cleared'})
        self.assertNotIn('WMST',dumps(retrieve(self.map,'Which motorcycle school did I choose?',prior='')))

    def test_named_entity_does_not_match_inside_an_unrelated_word(self):
        self.fact('Art','description','Unrelated person')
        self.assertNotIn('Unrelated person',dumps(retrieve(self.map,'Can we depart?',prior='')))

    def test_completed_commitment_is_available_before_reminding_again(self):
        self.map.execute("insert into memory.plans(day,item,status,origin,outcome_note,created_by) values(current_date-1,'Strala interview','done','user','Completed and advanced to technical round','test')")
        self.assertIn('Completed and advanced',dumps(retrieve(self.map,'Strala interview',prior='')['commitments']))
