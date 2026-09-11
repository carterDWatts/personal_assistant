import os
import unittest

from engine import config, engine
from tst.helpers import FakeRuntime, FakeTerminal, MapTest, call, say


class engine_test(MapTest):
    def test_talk_queues_memory_without_write_tools(self):
        self.map.execute("insert into memory.attributes (name, value_type, cardinality, created_by) values ('parked_at', 'text', 'single', 'test')")
        rt = FakeRuntime([
            [say("Got it. Where is it?")],
            [say("Noted, the garage.")],
        ])
        io = FakeTerminal(["I have a Porsche", "it's in the garage"])
        self.run_async(engine.run("talk", self.map, rt, io, "mac"))

        self.assertIn(f"You are {config.ASSISTANT_NAME},", rt.opened["system_prompt"])
        self.assertNotIn("morning session", rt.opened["system_prompt"])
        self.assertIsNone(rt.opened["resume"])
        self.assertIn("Map snapshot.", rt.sent[0])
        self.assertTrue(rt.sent[0].endswith("The user says:\nI have a Porsche"))
        self.assertTrue(rt.sent[1].endswith("it's in the garage"))
        self.assertEqual("".join(io.out), "Got it. Where is it?Noted, the garage.")

        rows = self.map.rows("select role, content, payload from memory.messages order by id")
        roles = [r["role"] for r in rows]
        self.assertEqual(roles, ["user", "assistant", "user", "assistant"])
        self.assertEqual(rows[0]["content"], "I have a Porsche")
        self.assertEqual(rows[1]["content"], "Got it. Where is it?")
        self.assertNotIn("entity_upsert", rt.tools)
        self.assertEqual(self.map.value("select count(*) from memory.memory_jobs where status='pending'"), 2)
        self.assertEqual(self.map.value("select count(*) from memory.entities"), 0)

        seg = self.map.row("select runtime_session_id, ended_by, metrics from memory.conversations")
        self.assertEqual(seg["runtime_session_id"], "fake-session-1")
        self.assertEqual(seg["ended_by"], "user")
        self.assertEqual(seg["metrics"]["turns"], 2)
        self.assertTrue(rt.closed)

    def test_email_drafts_remain_attached_to_the_reply_after_reopening(self):
        import json
        from engine.runtime import Event
        receipt = Event("tool_result", name="google_mail_draft", payload={"content": json.dumps({"needs_review":True,"draft":{"id":"example-draft"}})})
        rt = FakeRuntime([[receipt, receipt]])
        self.run_async(engine.run("talk", self.map, rt, FakeTerminal(["Write an email"]), "mac"))
        row = self.map.row("select content,payload from memory.messages where role='assistant'")
        self.assertEqual(row['payload']['email_drafts'],['example-draft'])
        self.assertIn('review',row['content'])

    def test_clear_starts_fresh_and_stays_clear_on_reopen(self):
        first = FakeRuntime([[say("old answer")]])
        self.run_async(engine.run("talk", self.map, first, FakeTerminal(["old user message"]), "mac"))
        cleared = FakeRuntime([[say("fresh answer")]])
        self.run_async(engine.run("clear", self.map, cleared, FakeTerminal(["new message"]), "mac"))
        self.assertIsNone(cleared.opened["resume"])
        self.assertNotIn("old user message", cleared.sent[0])
        self.assertNotIn("old answer", cleared.sent[0])
        from engine.conversation import Conversation
        conv = Conversation(self.map, "mac", "fake")
        self.assertEqual([r["content"] for r in conv.tail(100)], ["new message", "fresh answer"])
        self.assertEqual(self.map.value("select count(*) from memory.messages where content='old user message'"), 1)
        self.assertEqual(self.map.value("select count(*) from memory.memory_jobs"), 2)
        # Another runtime must not revive a session or seed from before Clear.
        other = Conversation(self.map, "mac", "other")
        _, resume, seed = other.resolve("talk")
        self.assertIsNone(resume)
        self.assertNotIn("old user message", seed)
        self.assertIn("new message", seed)

    def test_morning_speaks_first_with_the_morning_instructions(self):
        rt = FakeRuntime([[say("Morning. Nothing on the plan yet. What are you doing today?")], [say("Gym it is.")]])
        io = FakeTerminal(["gym at six"])
        self.run_async(engine.run("morning", self.map, rt, io, "mac"))
        self.assertIn("morning session", rt.opened["system_prompt"])
        self.assertTrue(rt.sent[0].startswith("Map snapshot."))
        self.assertTrue(rt.sent[0].endswith("Begin the morning session."))
        self.assertTrue(rt.sent[1].endswith("gym at six"))
        roles = [r["role"] for r in self.map.rows("select role from memory.messages order by id")]
        self.assertEqual(roles, ["system", "assistant", "user", "assistant"])

    def test_resumed_session_gets_fresh_snapshot(self):
        first = FakeRuntime([[say("hi")]])
        self.run_async(engine.run("talk", self.map, first, FakeTerminal(["hello"]), "mac"))
        second = FakeRuntime([[say("still here")]])
        self.run_async(engine.run("talk", self.map, second, FakeTerminal(["you there?"]), "mac"))
        self.assertEqual(second.opened["resume"], "fake-session-1")
        self.assertIn("Map snapshot.", second.sent[0])
        self.assertTrue(second.sent[0].endswith("you there?"))

    def test_interrupted_morning_survives_a_new_runtime_before_its_first_message(self):
        from engine.conversation import Conversation
        from engine.routine import progress
        morning = Conversation(self.map, 'cloud', 'previous-runtime').open_segment('morning')
        rt = FakeRuntime([[call('routine_progress', steps=['Calendar', 'Reminders', 'Updates']),
                           say('Here is your calendar.')], [say('Here are your reminders.')]])
        io = FakeTerminal(['Let’s plan my day.', 'Let’s move on.'])
        self.run_async(engine.run('talk', self.map, rt, io, 'cloud'))
        self.assertIn('morning session', rt.opened['system_prompt'])
        self.assertIn('routine_progress', rt.tools)
        self.assertIn('"state": "not_started"', rt.sent[0])
        self.assertIn('"current": "Reminders"', rt.sent[1])
        self.assertEqual(progress(self.map, morning)['position'], 1)

    def test_routine_progress_survives_model_changes_and_stays_complete(self):
        from engine.routine import progress
        first = FakeRuntime([[call('routine_progress', steps=['Calendar', 'Updates']),
                              call('routine_progress', completed_step='Calendar'), say('Next: updates.')]])
        self.run_async(engine.run('morning', self.map, first, FakeTerminal([]), 'cloud'))
        second = FakeRuntime([[call('routine_progress', completed_step='Updates'), say('All covered.')]])
        second.name = 'another-runtime'
        self.run_async(engine.run('talk', self.map, second, FakeTerminal(['Continue']), 'phone'))
        self.assertIn('"current": "Updates"', second.sent[0])
        third = FakeRuntime([[say('What else is on your mind?')]])
        self.run_async(engine.run('talk', self.map, third, FakeTerminal(['Move on']), 'mac'))
        self.assertIn('"state": "complete"', third.sent[0])
        morning = self.map.value("select id from memory.conversations where agent='morning'")
        self.assertEqual(progress(self.map, morning)['position'], 2)

    def test_clear_and_a_new_day_do_not_revive_the_previous_morning(self):
        from engine.conversation import Conversation
        from engine.routine import active
        conv = Conversation(self.map, 'cloud', 'fake')
        old = conv.open_segment('morning')
        self.map.execute("update memory.conversations set started_at=current_date-interval '1 day' where id=%s", (old,))
        self.assertIsNone(active(self.map))
        fresh = conv.open_segment('morning')
        self.assertEqual(active(self.map), fresh)
        rt = FakeRuntime([[say('Fresh chat.')]])
        self.run_async(engine.run('clear', self.map, rt, FakeTerminal(['Hello']), 'cloud'))
        self.assertNotIn('routine_progress', rt.tools)
        self.assertIsNone(active(self.map))

    @unittest.skipUnless(os.environ.get('ASSISTANT_LIVE_ROUTINE_TEST') == '1', 'Opt-in subscription test')
    def test_live_morning_moves_on_after_acknowledgment_and_interruption(self):
        import asyncio
        from unittest.mock import patch
        from engine.conversation import Conversation
        from engine.routine import progress
        from engine.runtime.codex import CodexRuntime
        self.map.execute("insert into memory.rules(kind,text,created_by) values('preference',%s,'test')", (
            'My morning has three sections: calendar, reminders, then a garden check. Pause after each section. '
            'Keep it brief. I have no events or reminders today. The garden needs watering.',))
        morning = Conversation(self.map, 'cloud', 'interrupted-runtime').open_segment('morning')
        async def check():
            runtime = CodexRuntime(model='gpt-5.5', effort='low')
            session = engine.Session(self.map, runtime, FakeTerminal([]), 'cloud', auto_memory=False)
            try:
                await session.open('talk')
                await session.send('Let’s plan my day.')
                self.assertNotEqual(progress(self.map, morning)['state'], 'not_started')
                position = progress(self.map, morning)['position']
                await session.send('OK, cool.')
                self.assertGreater(progress(self.map, morning)['position'], position)
                position = progress(self.map, morning)['position']
                await session.close()
                session = engine.Session(self.map, CodexRuntime(model='gpt-5.5', effort='low'), FakeTerminal([]), 'phone', auto_memory=False)
                await session.open('talk')
                self.assertEqual(session.routine_id, morning)
                await session.send('Move on')
                self.assertGreater(progress(self.map, morning)['position'], position)
                await session.send('OK, cool.')
                self.assertEqual(progress(self.map, morning)['state'], 'complete')
            finally:
                await session.close()
        # No external service tools or production memory are available to this probe.
        with patch.object(config, 'ENV', 'test'), patch.object(engine.Tools, 'read_specs', side_effect=lambda *_: []):
            self.run_async(asyncio.wait_for(check(), 120))


if __name__ == "__main__":
    unittest.main()


class identity_test(unittest.TestCase):
    def test_persona_uses_the_configured_name(self):
        from unittest.mock import patch
        with patch.object(config, "ASSISTANT_NAME", "Another name"):
            persona = config.prompt("persona")
        self.assertIn("You are Another name,", persona)
        self.assertNotIn("{{assistant_name}}", persona)
        self.assertNotIn(config.ASSISTANT_NAME, persona)


class runtime_recovery_test(MapTest):
    def test_large_runtime_context_reseeds_without_losing_the_conversation(self):
        from engine.engine import Session
        from unittest.mock import AsyncMock
        rt=FakeRuntime([[say('Still here.')]])
        rt.context_tokens=100000
        rt.restart=AsyncMock()
        async def use():
            session=Session(self.map,rt,FakeTerminal([]),'test',auto_memory=False)
            await session.open()
            previous=session.conv.record(session.segment_id,'user','Keep the existing task in mind.')
            await session.send('Continue')
            self.assertEqual(rt.restart.await_count,1)
            self.assertIn('Keep the existing task in mind.',rt.sent[0])
            self.assertTrue(self.map.value('select exists(select 1 from memory.messages where id=%s)',(previous,)))
            await session.close()
        self.run_async(use())
