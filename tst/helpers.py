"""Test scaffolding: a map on the test database, wiped between tests, and fakes for the runtime and terminal."""

import asyncio
import os
import unittest
from urllib.parse import urlsplit

from engine.db import Map
from engine.runtime import Event, Metrics

TEST_URL = os.environ.get("ASSISTANT_TEST_DATABASE_URL")

TABLES = ("memory_jobs", "relationship_sources", "revisions", "assertion_sources", "assertions", "relationships", "entity_aliases", "entity_embeddings", "entities",
          "plans", "rules", "questions", "connectors", "messages", "conversations", "observations", "attributes", "relations")


class MapTest(unittest.TestCase):
    """A test with a clean map. Skipped unless ASSISTANT_TEST_DATABASE_URL points at a database with the migrations applied."""

    def setUp(self):
        if not TEST_URL:
            self.skipTest("ASSISTANT_TEST_DATABASE_URL is not set; run scripts/test.sh")
        target = urlsplit(TEST_URL)
        if target.hostname not in ("localhost", "127.0.0.1", "::1") or target.port not in (55432, 55433):
            raise RuntimeError("Destructive tests require the local test database on port 55432 or 55433")
        self.map = Map(TEST_URL)
        self.map.execute("truncate " + ", ".join(f"memory.{t}" for t in TABLES) + " restart identity cascade")

    def tearDown(self):
        if getattr(self, "map", None):
            self.map.close()

    def run_async(self, coro):
        return asyncio.run(coro)


class FakeRuntime:
    """Yields scripted events. Each script entry is the list of events for one send()."""

    name = "fake"

    def __init__(self, script):
        self.script = list(script)
        self.session_id = None
        self.sent = []
        self.opened = None
        self.closed = False
        self.tools = None

    async def open(self, system_prompt, tools, resume=None):
        self.opened = {"system_prompt": system_prompt, "resume": resume}
        self.tools = {t.name: t for t in tools}

    async def send(self, text):
        self.sent.append(text)
        if not self.script:
            raise AssertionError("fake runtime ran out of script")
        events = self.script.pop(0)
        for ev in events:
            if callable(ev):
                ev = await ev(self)
            yield ev
        self.session_id = self.session_id or "fake-session-1"
        yield Event("done", payload=Metrics(cost_usd=0.01, turns=1).as_dict())

    async def close(self):
        self.closed = True
        return Metrics(cost_usd=0.01 * len(self.sent), turns=len(self.sent))

    async def interrupt(self):
        self.interrupted = True


class FakeTerminal:
    def __init__(self, inputs):
        self.inputs = list(inputs)
        self.out = []
        self.notes = []

    def read(self):
        return self.inputs.pop(0) if self.inputs else None

    def start_turn(self):
        pass

    def delta(self, text):
        self.out.append(text)

    def end_turn(self):
        pass

    def note(self, text):
        self.notes.append(text)

    def close(self):
        pass


def say(text):
    return Event("assistant_text", text=text)


def call(tool, **args):
    """A scripted tool call: runs the real tool against the map, like the runtime would."""
    async def run(rt):
        from engine import tools
        text, is_error = await tools.run(rt.tools[tool], args)
        rt.last_result = (text, is_error)
        return Event("tool_use", name=tool, payload=args)
    return run
