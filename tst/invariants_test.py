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
