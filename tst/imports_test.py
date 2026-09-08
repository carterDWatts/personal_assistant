import uuid
from engine.db import jsonb
from engine.imports import validate_history
from engine.memory_worker import Worker
from engine.context import pending_block
from engine.conversation import Conversation
from tst.helpers import MapTest

class imports_test(MapTest):
    def put(self, **changes):
        args = dict(id=str(self.id), title='Old chat', kind='history', runtime='codex', parts=2, part=0, text='User: My bike was blue.\n')
        args.update(changes)
        return self.map.value('select memory.import_part(%s)', (jsonb(args),))

    def setUp(self):
        super().setUp()
        self.id = uuid.uuid4()

    def test_upload_is_lossless_atomic_and_replay_safe(self):
        self.put()
        self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'), 0)
        self.put(part=1, text='Assistant: Is it still blue?')
        self.put(part=1, text='Assistant: Is it still blue?')
        self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'), 2)
        self.assertEqual(self.map.value("select string_agg(content,'' order by part) from memory.import_parts"), 'User: My bike was blue.\nAssistant: Is it still blue?')
        self.assertEqual(Conversation(self.map,'test','codex').tail(100), [])
        self.assertNotIn('blue', pending_block(self.map))
        with self.assertRaises(Exception): self.put(text='Changed')
        self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'), 2)

    def test_invalid_part_cannot_leave_partial_import(self):
        with self.assertRaises(Exception): self.put(part=9)
        self.assertEqual(self.map.value('select count(*) from memory.imports'), 0)

    def test_historical_import_cannot_claim_current_state(self):
        for tool, args in [('fact_assert', {}), ('rule_add', {}), ('plan_add', {}), ('fact_deprecate', {})]:
            with self.assertRaises(ValueError): validate_history(tool, args)
        validate_history('fact_assert', {'valid_from':'2020-01-01T00:00:00Z','valid_to':'2021-01-01T00:00:00Z'})
        validate_history('question_add', {'text':'Is your bicycle still blue?'})

    def test_live_message_precedes_import_backlog(self):
        self.put(parts=1)
        conv = Conversation(self.map,'test','codex')
        segment = conv.open_segment('talk')
        live = conv.record(segment,'user','I moved today.')
        self.assertEqual(Worker(self.map).oldest()['message_id'], live)
