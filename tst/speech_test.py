import asyncio
import base64
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock
from engine.speech import chunk, Speech

class speech_test(unittest.TestCase):
    def test_chunks_preserve_words_and_flush_remainder(self):
        source = 'Morning. ' + 'Here is a longer sentence with enough words to split safely before it goes on too long. ' * 4
        rest = source
        parts = []
        while True:
            part, rest = chunk(rest, True)
            if part is None: break
            parts.append(part)
        self.assertEqual(' '.join(' '.join(parts).split()), ' '.join(source.split()))

    def test_text_feed_does_not_wait_for_audio(self):
        async def check():
            host = SimpleNamespace()
            speech = Speech(host)
            speech.task = asyncio.create_task(asyncio.sleep(30))
            speech.queue = asyncio.Queue(maxsize=2)
            speech.feed('One. Two. Three. Four. ')
            self.assertTrue(speech.overflow)
            self.assertTrue(speech.cancel.is_set())
            speech.task.cancel()
            await asyncio.gather(speech.task, return_exceptions=True)
        asyncio.run(check())

    def test_audio_finishes_after_text_and_stays_in_order(self):
        async def check():
            events = []
            started, release = threading.Event(), threading.Event()
            class Relay:
                map = SimpleNamespace(execute=lambda *args: None)
                def cancelled(self, turn): return False
                def publish_speech(self, turn, payload): events.append(payload); return True
            async def call(method, *args): return method(*args)
            speech = Speech(SimpleNamespace(relay=Relay(), call=call))
            speech.voice = object()
            speech.storage = SimpleNamespace(upload=lambda name, data: 'https://example.test/' + name)
            speech.last_cleanup = __import__('time').monotonic()
            def render(text, cancel):
                started.set(); release.wait(3)
                return b'audio', 500
            speech.render = render
            await speech.begin({'id': 'turn', 'speech': True})
            speech.feed('... **. First sentence. Second sentence. ')
            speech.finish('completed')
            await asyncio.to_thread(started.wait, 2)
            self.assertFalse(speech.task.done())
            self.assertEqual(events, [])
            release.set()
            await speech.task
            self.assertEqual([event['type'] for event in events], ['speech', 'speech', 'speech_end'])
            self.assertEqual([event['seq'] for event in events[:-1]], [1, 2])
            self.assertEqual(events[-1]['status'], 'success')
            self.assertEqual(base64.b64decode(events[0]['url'].split(',', 1)[1]), b'audio')
        asyncio.run(check())
