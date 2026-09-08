"""Stream CPU speech independently of text completion. Audio never enters memory."""
import asyncio
import json
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
        self.queue = None
        self.overflow = False
        self.turn = None
        self.last_cleanup = 0
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
        self.overflow = False
        self.cancel = threading.Event()
        self.queue = asyncio.Queue(maxsize=32)
        if turn.get('speech'):
            self.task = asyncio.create_task(self.run(self.turn, self.cancel, self.queue))

    def feed(self, text):
        if not self.task or self.task.done(): return
        self.buffer += text
        while True:
            part, self.buffer = chunk(self.buffer, limit=36 if self.first_chunk else 180)
            if part is None: break
            if any(c.isalnum() for c in part): self.first_chunk = False
            self.enqueue(part)

    def enqueue(self, part):
        try: self.queue.put_nowait(part)
        except asyncio.QueueFull:
            self.overflow = True
            self.cancel.set()

    def finish(self, status):
        if not self.task: return
        if status != 'completed': self.cancel.set()
        part, self.buffer = chunk(self.buffer, True)
        if part: self.enqueue(part)
        self.enqueue(None)

    def render(self, text, cancelled):
        with self.render_lock:
            if cancelled.is_set(): return None
            return self.render_locked(text, cancelled)

    def render_locked(self, text, cancelled):
        result = self.voice.generate(text, sid=self.settings.get('speaker', 16), speed=self.settings.get('speed', 1.1),
                                     callback=lambda samples, progress: int(not cancelled.is_set()))
        if cancelled.is_set() or len(result.samples) == 0: return None
        import numpy as np
        samples = np.asarray(result.samples, dtype='<f4')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'speech.m4a'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'f32le', '-ar', str(result.sample_rate), '-ac', '1',
                            '-i', 'pipe:0', '-c:a', 'aac', '-b:a', '48k', '-movflags', '+faststart', str(output)],
                           input=samples.tobytes(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           check=True, timeout=20)
            return output.read_bytes(), round(len(samples) / result.sample_rate * 1000)

    async def run(self, turn, cancelled, queue):
        status = 'success'
        try:
            if not self.voice or not self.storage: raise RuntimeError('Speech not ready')
            await self.cleanup()
            seq = 0
            while not cancelled.is_set():
                if await self.host.call(self.host.relay.cancelled, turn): break
                try: text = await asyncio.wait_for(queue.get(), .3)
                except asyncio.TimeoutError: continue
                if text is None: break
                # Formatting is for the chat, not the voice.
                text = re.sub(r'[*#`]', '', text).strip()
                if not any(c.isalnum() for c in text): continue
                result = await asyncio.to_thread(self.render, text, cancelled)
                if cancelled.is_set(): break
                if result is None: continue
                if await self.host.call(self.host.relay.cancelled, turn): break
                seq += 1
                name = f'{turn}/{seq}.m4a'
                # Register before upload, so cleanup also covers a crash between upload and publish.
                await self.host.call(self.host.relay.map.execute,
                    'insert into assistant.speech_objects(path) values(%s) on conflict do nothing', (name,))
                url = await asyncio.to_thread(self.storage.upload, name, result[0])
                if cancelled.is_set(): break
                if not await self.host.call(self.host.relay.publish_speech, turn,
                    {'type': 'speech', 'seq': seq, 'url': url, 'duration_ms': result[1], 'text': text}): break
        except Exception as error:
            status = 'error'
            print(f'Speech failed ({type(error).__name__}).', flush=True)
        finally:
            if self.overflow: status = 'error'
            await self.host.call(self.host.relay.publish_speech, turn, {'type': 'speech_end', 'status': status})

    async def close(self):
        self.cancel.set()
        if self.task:
            # Interrupt I/O immediately. The generation callback stops CPU work and the lock
            # keeps a cancelled thread from overlapping the next ONNX call.
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
            self.task = None
