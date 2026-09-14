import sqlite3
import tempfile
import unittest
import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from pathlib import Path
from engine.runtime.storage import trim_logs


class runtime_storage_test(unittest.TestCase):
    def test_logs_shrink_without_touching_session_state(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            path = state / 'logs_2.sqlite'
            with sqlite3.connect(path) as db:
                db.execute('pragma auto_vacuum=incremental')
                db.execute('create table logs(id integer primary key, body text)')
                db.executemany('insert into logs(body) values(?)', [('x' * 4000,)] * 4000)
            sentinel = state / 'state_5.sqlite'
            sentinel.write_bytes(b'keep session state')
            auth = state / 'auth.json'
            auth.write_bytes(b'keep credentials')
            trim_logs(state, budget=2 * 1024 * 1024, seconds=10)
            self.assertLessEqual(path.stat().st_size, 2 * 1024 * 1024)
            with sqlite3.connect(path) as db:
                self.assertEqual(db.execute('pragma integrity_check').fetchone()[0], 'ok')
            self.assertEqual(sentinel.read_bytes(), b'keep session state')
            self.assertEqual(auth.read_bytes(), b'keep credentials')

    def test_unknown_log_schema_does_not_break_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            path = state / 'logs_99.sqlite'
            path.write_bytes(b'not sqlite')
            trim_logs(state, budget=1)
            self.assertEqual(path.read_bytes(), b'not sqlite')


class runtime_recovery_test(unittest.IsolatedAsyncioTestCase):
    async def test_missing_models_are_published_when_discovery_recovers(self):
        from engine.host import runtime_maintenance
        host = SimpleNamespace(ready=asyncio.Event(), stopping=asyncio.Event(), models=[],
                               speech_ready=False, relay=SimpleNamespace(capabilities=object()))
        host.ready.set()
        models = [{'id': 'codex/test', 'runtime': 'codex', 'model': 'test'}]
        async def publish(method, payload):
            self.assertIs(method, host.relay.capabilities)
            self.assertEqual(payload, {'models': models, 'speech': False, 'voices': []})
            host.stopping.set()
        host.call = AsyncMock(side_effect=publish)
        with patch('engine.runtime.storage.trim_logs'), patch('engine.models.available', new=AsyncMock(return_value=models)):
            await asyncio.wait_for(runtime_maintenance(host), 2)
        self.assertEqual(host.models, models)
        host.call.assert_awaited_once()
