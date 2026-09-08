import unittest
from datetime import date

from engine import context
from engine.db import jsonb
from tst.helpers import MapTest


class context_test(MapTest):
    def test_empty_map(self):
        text = context.snapshot(self.map, date(2026, 9, 7))
        self.assertIn("Today is Monday 2026-09-07", text)
        self.assertIn("Nothing recorded yet.", text)
        self.assertIn("Open questions, best first\nNone.", text)

    def test_populated_map(self):
        self.map.execute("insert into memory.attributes (name, value_type, cardinality, stale_after, created_by) values ('parked_at', 'text', 'single', interval '1 day', 'test')")
        self.map.execute("insert into memory.relations (name, cardinality, created_by) values ('employed_by', 'single', 'test')")
        car = self.map.call("upsert_entity", p_type="vehicle", p_name="Porsche", p_created_by="test")
        me = self.map.call("upsert_entity", p_type="person", p_name="Carter", p_created_by="test")
        acme = self.map.call("upsert_entity", p_type="organization", p_name="Acme", p_created_by="test")
        self.map.call("assert_fact", p_entity_id=car["id"], p_attribute="parked_at", p_value=jsonb("5th street"), p_asserted_by="test")
        self.map.call("assert_fact", p_entity_id=car["id"], p_attribute="parked_at", p_value=jsonb("garage"), p_asserted_by="test")
        self.map.execute("update memory.assertions set last_confirmed_at = now() - interval '3 days' where upper_inf(valid)")
        self.map.call("assert_relationship", p_subject_id=me["id"], p_relation="employed_by", p_object_id=acme["id"], p_asserted_by="test")
        self.map.execute("insert into memory.rules (kind, text, created_by) values ('mandate', 'move my solo blocks', 'test')")
        self.map.execute("insert into memory.plans (day, item, status, origin, rationale, created_by) values (current_date, 'move the car', 'proposed', 'map', 'street cleaning', 'test')")
        self.map.execute("insert into memory.questions (kind, text, score, created_by) values ('stale', 'Still in the garage?', 3, 'test')")

        text = context.snapshot(self.map)
        self.assertIn("vehicle Porsche", text)
        self.assertIn("parked_at = garage [stale, re-verify]", text)
        self.assertIn("Carter employed_by Acme", text)
        self.assertIn("[mandate] move my solo blocks", text)
        self.assertIn("move the car, proposed because street cleaning", text)
        self.assertIn("Still in the garage? (stale, question 1)", text)
        self.assertIn("Porsche parked_at: 5th street -> garage", text)


if __name__ == "__main__":
    unittest.main()


class delta_test(unittest.TestCase):
    def test_changed_and_removed_sections_replace_old_state(self):
        old = {'facts': 'Facts\nBike = red', 'rules': 'Rules\nBe concise', 'pending': 'Pending\nBike is blue'}
        new = {'facts': 'Facts\nBike = blue', 'rules': old['rules'], 'pending': 'Pending\nNone pending.'}
        delta = context.update(old, new)
        self.assertIn('Bike = blue', delta)
        self.assertIn('None pending.', delta)
        self.assertNotIn('Bike = red', delta)
        self.assertNotIn('Be concise', delta)
        self.assertEqual(context.update(new, new), 'Memory checked; no changes.')
        self.assertIn('Be concise', context.update(None, new))
