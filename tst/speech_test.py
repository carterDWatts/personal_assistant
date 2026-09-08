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
                speech.feed('I can help you wi')
                for _ in range(50):
                    if events: break
                    await asyncio.sleep(.01)
                self.assertEqual(events[0]['text'], 'I can help you')
                self.assertFalse(speech.task.done())
                speech.feed('th that.')
                speech.finish('completed')
                await speech.task
                self.assertEqual([e['text'] for e in events if e['type'] == 'speech'], ['I can help you', 'with that.'])
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

    def test_links_abbreviations_and_decimals_remain_whole(self):
        from engine.voice.phrasing import spoken
        text='Ask Dr. Smith about the 3.5 mile walk. Then see [the forecast](https://example.com/forecast).'
        part,rest=chunk(text)
        self.assertEqual(part,'Ask Dr. Smith about the 3.5 mile walk.')
        self.assertEqual(spoken(rest),'Then see the forecast.')
        link='[the forecast](https://example.com/'+'x'*100+') is helpful.'
        part,rest=chunk(link,limit=40)
        self.assertIsNone(part)
        self.assertEqual(spoken(chunk(rest,True)[0]),'the forecast is helpful.')
        self.assertEqual(spoken('## Today\n- **Gym** at 9\n- Lunch at noon'),'Today Gym at 9 Lunch at noon')

    def test_audio_padding_preserves_quiet_edges_and_punctuation_pause(self):
        import numpy as np
        from engine.voice.phrasing import trim_padding
        rate=24000
        speech=np.concatenate([np.ones(240)*.001,np.ones(2400)*.1,np.ones(240)*.001])
        padded=np.concatenate([np.zeros(12000),speech,np.zeros(12000)])
        sentence=trim_padding(padded,rate,'That works.')
        fragment=trim_padding(padded,rate,'That works')
        self.assertLess(len(sentence),len(padded))
        self.assertGreater(len(sentence),len(fragment))
        np.testing.assert_array_equal(sentence[840:840+len(speech)],speech)

    def test_streamed_audio_arrives_before_synthesis_finishes(self):
        import numpy as np
        async def check():
            events=[]
            release=threading.Event()
            def stream(text,cancel):
                yield np.ones(7680,dtype=np.float32)*.1
                release.wait(2)
                if not cancel.is_set(): yield np.ones(23040,dtype=np.float32)*.2
            class Relay:
                def publish_speech(self,turn,payload): events.append(payload); return True
            async def call(fn,*args): return fn(*args)
            speech=Speech(SimpleNamespace(relay=Relay(),call=call))
            speech.voice=SimpleNamespace(stream=stream,sample_rate=24000)
            speech.storage=object()
            await speech.begin({'id':'test','speech':True})
            try:
                speech.feed('That works. ')
                speech.finish('completed')
                for _ in range(100):
                    if events: break
                    await asyncio.sleep(.01)
                self.assertEqual(events[0]['duration_ms'],320)
                self.assertFalse(speech.task.done())
                release.set()
                await speech.task
                self.assertEqual([e['seq'] for e in events if e['type']=='speech'],[1,2])
                self.assertEqual(events[-1]['status'],'success')
            finally:
                release.set()
                await speech.close()
        asyncio.run(check())
