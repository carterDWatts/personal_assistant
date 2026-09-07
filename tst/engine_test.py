import unittest

from engine import engine
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

        self.assertIn("Carter's assistant", rt.opened["system_prompt"])
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


if __name__ == "__main__":
    unittest.main()
