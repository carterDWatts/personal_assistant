import asyncio
from datetime import datetime, timedelta, timezone
from engine.db import jsonb
from engine.engine import Session
from engine.runtime import Event
from engine.tools import Tools, run
from tst.helpers import MapTest, FakeRuntime, FakeTerminal


class invariants_test(MapTest):
    def setUp(self):
        super().setUp()
        self.entity = self.map.call('upsert_entity', p_type='person', p_name='Example', p_created_by='test')['id']
        self.map.execute("insert into memory.attributes(name,value_type,cardinality,created_by) values ('location','text','single','test')")

    def fact(self, value, start, end=None):
        return self.map.call('assert_fact', p_entity_id=self.entity, p_attribute='location', p_value=jsonb(value), p_asserted_by='test', p_valid_from=start, p_valid_to=end)

    def test_future_and_finite_validity(self):
        now = datetime.now(timezone.utc)
        self.fact('here', now - timedelta(days=1), now + timedelta(days=1))
        self.fact('there', now + timedelta(days=1))
        self.assertEqual(self.map.value('select value from memory.current_assertions'), 'here')
        self.map.execute('update memory.entities set retired_at=now() where id=%s', (self.entity,))
        self.assertEqual(self.map.value('select count(*) from memory.current_assertions'), 0)

    def test_retraction_is_not_a_transition_to_a_later_unrelated_fact(self):
        now = datetime.now(timezone.utc)
        old = self.fact('here', now - timedelta(days=3))
        self.map.call('retract_fact', p_assertion_id=old['id'], p_asserted_by='test', p_valid_to=now - timedelta(days=2))
        self.fact('there', now - timedelta(days=1))
        self.assertIsNone(self.map.value('select superseded_by from memory.assertions where id=%s', (old['id'],)))

    def test_failed_tool_rolls_back_observation_and_zero_confidence_survives(self):
        tools = {s.name:s for s in Tools(self.map,'test').specs()}
        before = self.map.value('select count(*) from memory.observations')
        _, failed = self.run_async(run(tools['fact_assert'], {'entity_id':str(self.entity),'attribute':'missing','value':'bad'}))
        self.assertTrue(failed)
        self.assertEqual(self.map.value('select count(*) from memory.observations'), before)
        _, failed = self.run_async(run(tools['fact_assert'], {'entity_id':str(self.entity),'attribute':'location','value':'here','confidence':0}))
        self.assertFalse(failed)
        self.assertEqual(self.map.value('select confidence from memory.current_assertions'),0)

    def test_partial_reply_is_saved_after_failure(self):
        class Broken(FakeRuntime):
            async def send(self, text):
                yield Event('text', text='A partial reply')
                raise RuntimeError('disconnected')
        async def exercise():
            session = Session(self.map, Broken([]), FakeTerminal([]), 'test')
            await session.open()
            try:
                with self.assertRaises(RuntimeError): await session.send('hello')
            finally: await session.close()
        asyncio.run(exercise())
        row = self.map.row("select content,payload from memory.messages where role='assistant'")
        self.assertEqual(row['content'],'A partial reply')
        self.assertTrue(row['payload']['interrupted'])
        self.assertEqual(self.map.value('select ended_by from memory.conversations'),'error')

    def test_inference_cannot_replace_a_stated_fact(self):
        now = datetime.now(timezone.utc)
        original=self.fact('confirmed',now-timedelta(days=1))
        from psycopg.errors import RaiseException
        with self.assertRaises(RaiseException):
            self.map.call('assert_fact',p_entity_id=self.entity,p_attribute='location',p_value=jsonb('guessed'),p_asserted_by='test',p_level='inferred')
        self.assertEqual(self.map.value('select id from memory.current_assertions'),original['id'])

    def test_revision_records_previous_value_and_predicate_type_is_protected(self):
        now=datetime.now(timezone.utc)
        old=self.fact('here',now-timedelta(days=1))
        self.fact('there',now)
        revision=self.map.row("select previous,replacement from memory.revisions where row_id=%s order by id limit 1",(old['id'],))
        self.assertEqual(revision['previous']['value'],'here')
        self.assertNotEqual(revision['previous']['valid'],revision['replacement']['valid'])
        from psycopg.errors import RaiseException
        with self.assertRaises(RaiseException):
            self.map.execute("update memory.attributes set cardinality='multi' where name='location'")

    def test_open_session_receives_messages_written_elsewhere(self):
        from engine.conversation import Conversation
        from tst.helpers import say
        async def exercise():
            runtime=FakeRuntime([[say('Understood')]])
            session=Session(self.map,runtime,FakeTerminal([]),'mac')
            await session.open()
            other=Conversation(self.map,'phone','fake')
            segment=other.open_segment('talk')
            other.record(segment,'user','I changed the trip to Monday')
            try:await session.send('What changed?')
            finally:await session.close()
            self.assertIn('I changed the trip to Monday',runtime.sent[0])
        self.run_async(exercise())

    def test_relationship_reconfirmation_keeps_both_sources(self):
        from psycopg.types.numeric import Int8
        other=self.map.call('upsert_entity',p_type='person',p_name='Other',p_created_by='test')['id']
        self.map.execute("insert into memory.relations(name,cardinality,created_by) values('knows','multi','test')")
        for text in ['first source','second source']:
            obs=self.map.call_value('record_observation',p_source='test',p_kind='statement',p_content=text)
            row=self.map.call('assert_relationship',p_subject_id=self.entity,p_relation='knows',p_object_id=other,p_asserted_by='test',p_observation_id=Int8(obs))
        self.assertEqual(self.map.value('select count(*) from memory.relationship_sources where relationship_id=%s',(row['id'],)),2)

    def test_missing_runtime_thread_restores_shared_history(self):
        from engine.conversation import Conversation
        from tst.helpers import say
        conversation=Conversation(self.map,'mac','fake')
        segment=conversation.open_segment('talk')
        conversation.record(segment,'user','Earlier context worth keeping')
        conversation.set_runtime_session(segment,'missing-runtime-thread')
        class Recreated(FakeRuntime):
            resumed=False
        async def exercise():
            runtime=Recreated([[say('Restored')]])
            session=Session(self.map,runtime,FakeTerminal([]),'mac')
            await session.open()
            try:await session.send('Continue')
            finally:await session.close()
            self.assertIn('Earlier context worth keeping',runtime.sent[0])
        self.run_async(exercise())
