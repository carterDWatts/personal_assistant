import json
import unittest
from datetime import date, timedelta

from engine import tools as tools_mod
from engine.tools import Tools
from tst.helpers import MapTest


class tools_test(MapTest):
    def setUp(self):
        super().setUp()
        self.tools = Tools(self.map, "mac")
        self.by_name = {t.name: t for t in self.tools.specs()}

    def call(self, tool, **args):
        text, is_error = self.run_async(tools_mod.run(self.by_name[tool], args))
        return json.loads(text) if not is_error else {"error": text}

    def test_specs_are_complete(self):
        for spec in self.tools.specs():
            self.assertTrue(spec.description, spec.name)
            self.assertEqual(spec.schema["type"], "object")
            for r in spec.schema["required"]:
                self.assertIn(r, spec.schema["properties"], spec.name)

    def test_entities_facts_and_history(self):
        self.call("attribute_register", name="parked at", value_type="text", cardinality="single", stale_after_days=3, importance=3)
        car = self.call("entity_upsert", type="vehicle", name="Porsche", aliases=["the car"], statement="my porsche")
        same = self.call("entity_upsert", type="vehicle", name="the car")
        self.assertEqual(car["id"], same["id"])

        yesterday = (date.today() - timedelta(days=1)).isoformat() + "T09:00:00"
        a1 = self.call("fact_assert", entity_id=car["id"], attribute="parked_at", value="5th street", valid_from=yesterday,
                       statement="car is on 5th")
        a2 = self.call("fact_assert", entity_id=car["id"], attribute="parked_at", value="5th street")
        self.assertEqual(a1["id"], a2["id"])
        a3 = self.call("fact_assert", entity_id=car["id"], attribute="parked_at", value="garage")
        self.assertNotEqual(a1["id"], a3["id"])

        view = self.call("entity_view", entity_id=car["id"])
        self.assertEqual([f["value"] for f in view["facts"]], ["garage"])
        self.assertEqual(len(view["transitions"]), 1)
        history = self.call("fact_history", entity_id=car["id"], attribute="parked_at")
        self.assertEqual([h["value"] for h in history], ["5th street", "garage"])

        # narrating the past: a closed interval in the gap before yesterday
        past = self.call("fact_assert", entity_id=car["id"], attribute="parked_at", value="airport lot",
                         valid_from=(date.today() - timedelta(days=5)).isoformat() + "T09:00:00", valid_to=yesterday)
        self.assertIsNotNone(past["valid"]["to"])
        self.assertEqual([f["value"] for f in self.call("entity_view", entity_id=car["id"])["facts"]], ["garage"])

        found = self.call("map_search", query="porsche")
        self.assertEqual(found["entities"][0]["entity_id"], car["id"])
        found = self.call("map_search", query="garage")
        self.assertEqual(found["facts"][0]["value"], "garage")

        obs = self.map.rows("select kind, content, message_id, agent from memory.observations order by id")
        self.assertTrue(all(o["agent"] == "mac" for o in obs))
        self.assertIn("car is on 5th", [o["content"] for o in obs])
        sources = self.map.value("select count(*) from memory.assertion_sources where assertion_id = %s", (a1["id"],))
        self.assertEqual(sources, 2)

    def test_errors_come_back_as_text(self):
        result = self.call("fact_assert", entity_id="00000000-0000-0000-0000-000000000000", attribute="nope", value="x")
        self.assertIn("not registered", result["error"])
        result = self.call("plan_update", plan_id=999, status="done")
        self.assertIn("no plan 999", result["error"])
        result = self.call("question_update", question_id=1, action="fly")
        self.assertIn("unknown action", result["error"])

    def test_retract_deprecate_confirm(self):
        self.call("attribute_register", name="hobby", value_type="text", cardinality="multi")
        me = self.call("entity_upsert", type="person", name="Carter")
        h1 = self.call("fact_assert", entity_id=me["id"], attribute="hobby", value="climbing")
        self.call("fact_assert", entity_id=me["id"], attribute="hobby", value="cycling")
        self.call("fact_retract", assertion_id=h1["id"], statement="stopped climbing")
        view = self.call("entity_view", entity_id=me["id"])
        self.assertEqual([f["value"] for f in view["facts"]], ["cycling"])
        c = self.call("fact_confirm", assertion_id=view["facts"][0]["id"])
        self.assertEqual(c["strength"], 2)
        self.call("fact_deprecate", assertion_id=c["id"], statement="never cycled")
        self.assertEqual(self.call("entity_view", entity_id=me["id"])["facts"], [])

    def test_relationships(self):
        self.call("relation_register", name="employed by", cardinality="single", inverse="employs")
        me = self.call("entity_upsert", type="person", name="Carter")
        acme = self.call("entity_upsert", type="organization", name="Acme")
        globex = self.call("entity_upsert", type="organization", name="Globex")
        r1 = self.call("relationship_assert", subject_id=me["id"], relation="employed_by", object_id=acme["id"], properties={"title": "engineer"})
        r2 = self.call("relationship_assert", subject_id=me["id"], relation="employed_by", object_id=globex["id"], valid_from="2026-08-01T00:00:00-07:00")
        self.assertNotEqual(r1["id"], r2["id"])
        view = self.call("entity_view", entity_id=me["id"])
        self.assertEqual([r["object_name"] for r in view["relationships"]], ["Globex"])
        # Acme was asserted as starting today, after Globex began, so it was wrong rather than outdated
        self.assertEqual(self.map.value("select rank from memory.relationships where id = %s", (r1["id"],)), "deprecated")
        self.call("relationship_retract", relationship_id=r2["id"])
        self.assertEqual(self.call("entity_view", entity_id=me["id"])["relationships"], [])

    def test_plans_rules_questions_connectors(self):
        p = self.call("plan_add", day="today", item="gym", category="gym")
        proposal = self.call("plan_add", day="tomorrow", item="move the car", origin="map", status="proposed", rationale="street cleaning")
        self.assertEqual(proposal["status"], "proposed")
        done = self.call("plan_update", plan_id=p["id"], status="done", note="short one")
        self.assertIsNotNone(done["resolved_at"])
        self.assertEqual([x["item"] for x in self.call("plans_list", day="today")], ["gym"])

        r = self.call("rule_add", kind="mandate", text="move my solo blocks freely")
        self.assertEqual(self.call("rule_update", rule_id=r["id"], status="retired")["status"], "retired")
        t = self.call("tuning_set", key="question budget", value=1)
        self.assertEqual(t["key"], "question_budget")
        self.assertEqual(self.map.value("select value from memory.rules where kind='tuning' and status='active' and key='question_budget'"), 1)
        self.call("tuning_set", key="question_budget", value=3)
        self.assertEqual(self.map.value("select count(*) from memory.rules where kind='tuning' and key='question_budget' and status='active'"), 1)

        q = self.call("question_add", text="Is Alex Rivera the gym Alex?", kind="merge", score=3)
        self.assertEqual(self.call("question_update", question_id=q["id"], action="asked")["times_asked"], 1)
        self.assertIsNotNone(self.call("question_update", question_id=q["id"], action="answered", answer="yes")["closed_at"])
        q2 = self.call("question_add", text="later")
        self.assertIsNotNone(self.call("question_update", question_id=q2["id"], action="defer", days=10)["deferred_until"])

        c = self.call("connector_update", name="gmail", status="needs_setup", needs="grant read access")
        self.assertEqual(c["status"], "needs_setup")
        c = self.call("connector_update", name="gmail", status="enabled")
        self.assertEqual((c["status"], c["needs"]), ("enabled", "grant read access"))


if __name__ == "__main__":
    unittest.main()
