"""Stream CPU speech independently of text completion. Audio never enters memory."""
import asyncio
import base64
import json
import io
import wave
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

from engine import config


def chunk(buffer, flush=False, limit=180):
    # Prefer whole sentences; bound latency without splitting words.
    match = re.search(r'[.!?\n](?:\s|$)', buffer)
    if match and match.end() <= limit: return buffer[:match.end()].strip(), buffer[match.end():]
    if len(buffer) >= limit:
        end = buffer.rfind(' ', 0, limit)
        if end > 0: return buffer[:end], buffer[end + 1:]
        if len(buffer) >= limit: return buffer[:limit], buffer[limit:]
    if flush and buffer.strip(): return buffer.strip(), ''
    return None, buffer


class Storage:
    def __init__(self):
        self.url = os.environ['ASSISTANT_SUPABASE_URL'].rstrip('/')
        self.key = os.environ['ASSISTANT_STORAGE_KEY']

    def request(self, path, method='POST', data=None, mime='application/json'):
        request = urllib.request.Request(self.url + '/storage/v1/' + path, method=method, data=data,
            headers={'Authorization': 'Bearer ' + self.key, 'apikey': self.key, 'Content-Type': mime})
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)

    def upload(self, name, data):
        self.request('object/speech/' + name, data=data, mime='audio/mp4')
        result = self.request('object/sign/speech/' + name, data=b'{"expiresIn":600}')
        return self.url + '/storage/v1' + result['signedURL']

    def remove(self, names):
        if names: self.request('object/speech', method='DELETE', data=json.dumps({'prefixes': names}).encode())


class Speech:
    def __init__(self, host):
        self.host = host
        self.voice = None
        self.render_lock = threading.Lock()
        self.storage = None
        self.task = None
        self.cancel = threading.Event()
        self.buffer = ''
        self.first_chunk = True
        self.chunks_queued = 0
        self.first_flush = None
        self.queue = None
        self.overflow = False
        self.turn = None
        self.last_cleanup = 0
        self.last_audio_cleanup = 0
        self.settings = json.loads((config.ROOT / 'identity.json').read_text()).get('voice', {})

    async def start(self):
        if not os.environ.get('ASSISTANT_STORAGE_KEY'): return False
        try:
            from engine.voice.kokoro import create_voice
            self.storage = Storage()
            self.voice = await asyncio.to_thread(create_voice)
            # Warm the model before advertising readiness.
            await asyncio.to_thread(self.voice.generate, 'Ready.', sid=self.settings.get('speaker', 16))
            await self.cleanup()
            return True
        except Exception as error:
            print(f'Speech unavailable ({type(error).__name__}).', flush=True)
            return False

    async def cleanup(self):
        if time.monotonic() - self.last_audio_cleanup >= 60:
            # Audio is transient delivery data, never conversation memory.
            await self.host.call(self.host.relay.map.execute,
                "update assistant.events set payload=payload-'url' "
                "where created_at<now()-interval '10 minutes' and payload->>'url' like 'data:audio/%;base64,%'")
            self.last_audio_cleanup = time.monotonic()
        if time.monotonic() - self.last_cleanup < 3600: return
        names = await self.host.call(self.host.relay.map.rows,
            "select path from assistant.speech_objects where created_at < now()-interval '1 day' limit 100")
        if names:
            paths = [row['path'] for row in names]
            await asyncio.to_thread(self.storage.remove, paths)
            await self.host.call(self.host.relay.map.execute, 'delete from assistant.speech_objects where path=any(%s)', (paths,))
        self.last_cleanup = time.monotonic()

    async def begin(self, turn):
        await self.close()
        self.turn = turn['id']
        self.buffer = ''
        self.first_chunk = True
        self.chunks_queued = 0
        self.overflow = False
        self.cancel = threading.Event()
        # Queue text only; audio is rendered one clip at a time. Long replies
        # must not lose their remaining sentences because synthesis is slower.
        self.queue = asyncio.Queue()
        if turn.get('speech'):
            self.task = asyncio.create_task(self.run(self.turn, self.cancel, self.queue))

    def feed(self, text):
        if not self.task or self.task.done(): return
        self.buffer += text
        while True:
            # The second clip must be ready before the short opening finishes.
            limit = 36 if self.first_chunk else 90 if self.chunks_queued == 1 else 180
            part, self.buffer = chunk(self.buffer, limit=limit)
            if part is None: break
            if any(c.isalnum() for c in part): self.first_chunk = False
            self.enqueue(part)
        if self.first_chunk and (self.first_flush is None or self.first_flush.done()):
            self.first_flush = asyncio.create_task(self.flush_opening())

    async def flush_opening(self):
        # Start a short opening while later text is still arriving. A trailing
        # token can be half a word, so leave it for the next chunk.
        await asyncio.sleep(.06)
        if not self.first_chunk or self.cancel.is_set(): return
        boundary = self.buffer.rfind(' ')
        if boundary < 0: return
        opening = self.buffer[:boundary].strip()
        if len(opening.split()) < 2: return
        self.buffer = self.buffer[boundary + 1:]
        self.first_chunk = False
        self.enqueue(opening)

    def enqueue(self, part):
        try:
            self.queue.put_nowait(part)
            if part and any(c.isalnum() for c in part): self.chunks_queued += 1
        except asyncio.QueueFull:
            self.overflow = True
            self.cancel.set()

    def finish(self, status):
        if not self.task: return
        if self.first_flush: self.first_flush.cancel()
        if status != 'completed': self.cancel.set()
        part, self.buffer = chunk(self.buffer, True)
        if part: self.enqueue(part)
        self.enqueue(None)

    def render(self, text, cancelled):
        with self.render_lock:
            if cancelled.is_set(): return None
            return self.render_locked(text, cancelled)

    def render_locked(self, text, cancelled):
        started = time.monotonic()
        result = self.voice.generate(text, sid=self.settings.get('speaker', 16), speed=self.settings.get('speed', 1.1),
                                     callback=lambda samples, progress: int(not cancelled.is_set()))
        generated = time.monotonic()
        if cancelled.is_set() or len(result.samples) == 0: return None
        import numpy as np
        samples = np.asarray(result.samples, dtype='<f4')
        # Opening phrases fit in a small PCM WAV. No encoder process or codec delay.
        # Longer clips stay compressed to keep network and replay payloads bounded.
        if len(samples) * 2 + 44 <= 64_000:
            output = io.BytesIO()
            with wave.open(output, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(result.sample_rate)
                wav.writeframes((np.clip(samples, -1, 1) * 32767).astype('<i2').tobytes())
            print(f'Synthesis timing: generate_seconds={generated-started:.3f} encode_seconds={time.monotonic()-generated:.3f} format=wav', flush=True)
            return output.getvalue(), round(len(samples) / result.sample_rate * 1000)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'speech.m4a'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'f32le', '-ar', str(result.sample_rate), '-ac', '1',
                            '-i', 'pipe:0', '-c:a', 'aac', '-b:a', '48k', '-movflags', '+faststart', str(output)],
                           input=samples.tobytes(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=True, timeout=20)
            print(f'Synthesis timing: generate_seconds={generated-started:.3f} encode_seconds={time.monotonic()-generated:.3f} format=aac', flush=True)
            return output.read_bytes(), round(len(samples) / result.sample_rate * 1000)

    async def run(self, turn, cancelled, queue):
        status = 'success'
        timings = {}
        try:
            if not self.voice or not self.storage: raise RuntimeError('Speech not ready')
            # Cleanup runs at startup and on the idle host heartbeat.
            seq = 0
            while not cancelled.is_set():
                try: text = await asyncio.wait_for(queue.get(), .3)
                except asyncio.TimeoutError: continue
                if text is None: break
                # Formatting is for the chat, not the voice.
                text = re.sub(r'[*#`]', '', text).strip()
                if not any(c.isalnum() for c in text): continue
                started = time.monotonic()
                result = await asyncio.to_thread(self.render, text, cancelled)
                rendered = time.monotonic()
                if cancelled.is_set(): break
                if result is None: continue
                # publish_speech checks cancellation atomically with publication.
                seq += 1
                if len(result[0]) <= 64_000:
                    mime = 'wav' if result[0].startswith(b'RIFF') else 'mp4'
                    url = f'data:audio/{mime};base64,' + base64.b64encode(result[0]).decode('ascii')
                else:
                    name = f'{turn}/{seq}.m4a'
                    await self.host.call(self.host.relay.map.execute,
                        'insert into assistant.speech_objects(path) values(%s) on conflict do nothing', (name,))
                    url = await asyncio.to_thread(self.storage.upload, name, result[0])
                if cancelled.is_set(): break
                if not await self.host.call(self.host.relay.publish_speech, turn,
                    {'type': 'speech', 'seq': seq, 'url': url, 'duration_ms': result[1], 'text': text,
                     'render_seconds': round(rendered-started, 3)}): break
                if seq == 1:
                    timings = {'render_seconds': round(rendered-started, 3),
                               'delivery_seconds': round(time.monotonic()-rendered, 3)}
                    print(f'Speech timing: render_seconds={rendered-started:.3f} delivery_seconds={time.monotonic()-rendered:.3f}', flush=True)
        except Exception as error:
            status = 'error'
            print(f'Speech failed ({type(error).__name__}).', flush=True)
        finally:
            if self.overflow: status = 'error'
            await self.host.call(self.host.relay.publish_speech, turn, {'type': 'speech_end', 'status': status, **timings})

    async def close(self):
        self.cancel.set()
        if self.first_flush:
            self.first_flush.cancel()
            await asyncio.gather(self.first_flush, return_exceptions=True)
            self.first_flush = None
        if self.task:
            # Interrupt I/O immediately. The generation callback stops CPU work and the lock
            # keeps a cancelled thread from overlapping the next ONNX call.
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
            self.task = None
