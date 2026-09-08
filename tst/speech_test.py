import asyncio
import base64
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from engine.speech import chunk, Speech

class speech_test(unittest.TestCase):
    def test_opening_plays_before_model_finishes_without_splitting_a_word(self):
        async def check():
            events = []
            class Relay:
                map = SimpleNamespace(execute=lambda *args: None)
                def cancelled(self, turn): return False
                def publish_speech(self, turn, payload): events.append(payload); return True
            async def call(method, *args): return method(*args)
            speech = Speech(SimpleNamespace(relay=Relay(), call=call))
            speech.voice = object()
            speech.storage = object()
            speech.last_cleanup = __import__('time').monotonic()
            speech.render = lambda text, cancel: (b'audio', 500)
            speech.cleanup = AsyncMock(side_effect=AssertionError('Cleanup blocked speech'))
            await speech.begin({'id': 'turn', 'speech': True})
            try:
                speech.feed('I can hel')
                for _ in range(50):
                    if events: break
                    await asyncio.sleep(.01)
                self.assertEqual(events[0]['text'], 'I can')
                self.assertFalse(speech.task.done())
                speech.feed('p with that.')
                speech.finish('completed')
                await speech.task
                self.assertEqual([e['text'] for e in events if e['type'] == 'speech'], ['I can', 'help with that.'])
                self.assertIn('render_seconds', events[-1])
                self.assertIn('delivery_seconds', events[-1])
                speech.cleanup.assert_not_awaited()
            finally:
                await speech.close()
        asyncio.run(check())

    def test_short_audio_skips_encoder_and_preserves_samples(self):
        import io
        import wave
        import numpy as np
        voice = SimpleNamespace(generate=lambda *args, **kwargs:
            SimpleNamespace(samples=np.array([-.5, 0, .5] * 100), sample_rate=24000))
        speech = Speech(SimpleNamespace())
        speech.voice = voice
        with patch('engine.speech.subprocess.run') as encoder:
            data, duration = speech.render('Hello.', threading.Event())
        encoder.assert_not_called()
        with wave.open(io.BytesIO(data)) as wav:
            self.assertEqual(wav.getframerate(), 24000)
            self.assertEqual(wav.getnframes(), 300)
            pcm = np.frombuffer(wav.readframes(300), dtype='<i2') / 32767
            np.testing.assert_allclose(pcm, voice.generate().samples, atol=1 / 32767)
        self.assertEqual(duration, 12)

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
            speech.queue = asyncio.Queue()
            speech.feed('A complete sentence. ' * 100)
            self.assertEqual(speech.queue.qsize(), 100)
            self.assertFalse(speech.overflow)
            self.assertFalse(speech.cancel.is_set())
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
            speech.feed('... **. ' + 'First sentence. Second sentence. ' * 30)
            speech.finish('completed')
            await asyncio.to_thread(started.wait, 2)
            self.assertFalse(speech.task.done())
            self.assertEqual(events, [])
            release.set()
            await speech.task
            self.assertEqual([event['type'] for event in events], ['speech'] * 60 + ['speech_end'])
            self.assertEqual([event['seq'] for event in events[:-1]], list(range(1, 61)))
            self.assertEqual(events[-1]['status'], 'success')
            self.assertEqual(base64.b64decode(events[0]['url'].split(',', 1)[1]), b'audio')
        asyncio.run(check())
