import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from engine.desktop import load_settings


class desktop_test(unittest.TestCase):
    def test_settings_are_literal_and_do_not_execute_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'.zshrc').write_text("export ASSISTANT_DATABASE_URL='postgresql://example:a$!b@host/db'\nexport ASSISTANT_TEST_DATABASE_URL=$(touch should-not-exist)\nexport UNRELATED_SECRET='ignored'\n")
            with patch('engine.desktop.Path.home',return_value=root), patch.dict(os.environ,{},clear=True):
                load_settings()
                self.assertEqual(os.environ['ASSISTANT_DATABASE_URL'],'postgresql://example:a$!b@host/db')
                self.assertNotIn('ASSISTANT_TEST_DATABASE_URL',os.environ)
                self.assertNotIn('UNRELATED_SECRET',os.environ)
                self.assertFalse((root/'should-not-exist').exists())

    def test_explicit_environment_takes_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'.zshrc').write_text("export ASSISTANT_DATABASE_URL='profile'\n")
            with patch('engine.desktop.Path.home',return_value=root),patch.dict(os.environ,{'ASSISTANT_DATABASE_URL':'explicit'},clear=True):
                load_settings()
                self.assertEqual(os.environ['ASSISTANT_DATABASE_URL'],'explicit')


class desktop_voice_test(unittest.IsolatedAsyncioTestCase):
    async def test_interrupted_reply_returns_ready_without_ending_voice(self):
        import asyncio
        import json
        import queue
        from engine import desktop
        incoming = queue.Queue()
        incoming.put(json.dumps({'type':'connect','runtime':'codex'}))
        events = []
        released = asyncio.Event()
        class Input:
            def readline(self):
                try: return incoming.get(timeout=3) + '\n'
                except queue.Empty: return ''
        class Runtime:
            async def interrupt(self): released.set()
        class Map:
            def row(self, *args): return {'pending':0,'errors':0}
            def close(self): pass
        class Conversation:
            def tail(self, n): return []
        class Session:
            def __init__(self, map_, runtime, io, device): self.runtime=runtime; self.conv=Conversation()
            async def open(self, mode): pass
            async def send(self, text):
                incoming.put(json.dumps({'type':'stop'}))
                await released.wait()
                raise RuntimeError('The reply was interrupted')
            async def close(self): pass
        def emit(kind, **values):
            events.append(kind)
            if kind == 'ready':
                incoming.put(json.dumps({'type':'send','text':'hello'} if events.count('ready') == 1 else {'type':'quit'}))
        with patch('engine.desktop.load_settings'), patch('engine.desktop.sys.stdin', Input()), patch('engine.desktop.emit',emit), patch('engine.db.Map',Map), patch('engine.engine.Session',Session), patch('engine.runtime.load',return_value=Runtime):
            await asyncio.wait_for(desktop.main(), 5)
        self.assertEqual(events.count('ready'), 2)
        self.assertNotIn('error', events)
