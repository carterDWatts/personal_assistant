import unittest

from engine.conversation import Conversation
from tst.helpers import MapTest


class conversation_test(MapTest):
    def test_first_talk_opens_a_segment_with_no_seed(self):
        conv = Conversation(self.map, "mac", "fake")
        segment, resume, seed = conv.resolve("talk")
        self.assertIsNotNone(segment)
        self.assertIsNone(resume)
        self.assertIsNone(seed)

    def test_same_device_resumes_until_another_device_speaks(self):
        mac = Conversation(self.map, "mac", "fake")
        s1, _, _ = mac.resolve("talk")
        mac.record(s1, "user", "hello")
        mac.record(s1, "assistant", "hi")
        mac.set_runtime_session(s1, "sess-1")

        again, resume, seed = mac.resolve("talk")
        self.assertEqual((again, resume, seed), (s1, "sess-1", None))

        phone = Conversation(self.map, "phone", "fake")
        s2, resume2, seed2 = phone.resolve("talk")
        self.assertNotEqual(s2, s1)
        self.assertIsNone(resume2)
        self.assertIn("user: hello", seed2)
        phone.record(s2, "user", "car is in the garage")
        phone.record(s2, "assistant", "noted")
        phone.set_runtime_session(s2, "sess-2")

        s3, resume3, seed3 = mac.resolve("talk")
        self.assertNotEqual(s3, s1)
        self.assertIsNone(resume3)
        self.assertIn("on phone] user: car is in the garage", seed3)
        self.assertTrue(seed3.index("user: hello") < seed3.index("car is in the garage"))

    def test_morning_always_starts_fresh(self):
        mac = Conversation(self.map, "mac", "fake")
        s1, _, _ = mac.resolve("talk")
        mac.record(s1, "user", "hello")
        mac.set_runtime_session(s1, "sess-1")
        s2, resume, seed = mac.resolve("morning")
        self.assertNotEqual(s2, s1)
        self.assertIsNone(resume)
        self.assertIn("hello", seed)

    def test_record_numbers_messages_and_close_keeps_metrics(self):
        conv = Conversation(self.map, "mac", "fake")
        s, _, _ = conv.resolve("talk")
        conv.record(s, "system", "opening", {"kind": "opening"})
        conv.record(s, "user", "hi")
        conv.record(s, "tool", None, {"call": "map_search", "input": {"query": "hi"}})
        rows = self.map.rows("select seq, role from memory.messages where conversation_id = %s order by seq", (s,))
        self.assertEqual([(r["seq"], r["role"]) for r in rows], [(1, "system"), (2, "user"), (3, "tool")])
        conv.close_segment(s, "user", {"cost_usd": 0.02, "turns": 1})
        row = self.map.row("select ended_by, metrics from memory.conversations where id = %s", (s,))
        self.assertEqual(row["ended_by"], "user")
        self.assertEqual(row["metrics"]["turns"], 1)


if __name__ == "__main__":
    unittest.main()
