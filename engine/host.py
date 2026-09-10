"""One long-lived subscription session serving the authenticated relay."""

import asyncio
import contextlib
import json
import signal
import os
import time
import psycopg

from engine import config
from engine.integrations.google import CONNECTION_ACTIONS
from engine.integrations.services import CONNECTION_ACTIONS as SERVICE_ACTIONS
from engine.db import Map
from engine.engine import Session
from engine.memory_worker import Worker as MemoryWorker
from engine.relay import Relay
from engine.runtime import load


class Stream:
    def __init__(self):
        self.pending = []
        self.audio = None
        self.timings = {}
        self.changed = asyncio.Event()

    def timing(self, name, seconds):
        self.timings[name] = round(seconds, 3)

    def input_saved(self, images):
        self.pending.append({"type":"images_saved","images":images})
        self.changed.set()

    def start_turn(self):
        pass  # Claiming the durable request already emitted start.

    def delta(self, text):
        if self.audio: self.audio(text)
        if self.pending and self.pending[-1]['type'] == 'delta':
            self.pending[-1]['text'] += text
        else:
            self.pending.append({'type': 'delta', 'text': text})
        self.changed.set()

    def replace_text(self, text):
        self.pending.append({'type': 'replace', 'text': text})
        self.changed.set()

    def note(self, name):
        self.pending.append({'type': 'status', 'text': name})
        self.changed.set()

    def tool_result(self, payload):
        try:
            result = json.loads(payload.get('content', ''))
        except (ValueError, TypeError):
            return
        if isinstance(result,dict) and result.get('image',{}).get('id'):
            self.pending.append({'type':'image','image':result['image'],'caption':result.get('caption','')})
            self.changed.set()
        if isinstance(result,dict) and result.get('needs_review') and result.get('draft',{}).get('id'):
            self.pending.append({'type':'email_draft','draft_id':result['draft']['id']})
            self.changed.set()
        if payload.get('is_error') and isinstance(result, dict) and result.get('connection_action') in CONNECTION_ACTIONS | SERVICE_ACTIONS:
            self.pending.append({'type': 'connection_required', 'action': result['connection_action'], 'session_id':result.get('session_id'), 'provider':result.get('provider'),
                                 'message': 'This service needs to be connected on this host.'})

    def end_turn(self):
        pass  # Terminal status belongs to the worker, including cancellation.

    def close(self):
        pass


class ReplyDeadline:
    """Wall-clock bounds, unaffected by reasoning/status traffic or tool calls."""
    def __init__(self, started):
        self.started = started
        self.notified = False

    def check(self, now, has_text):
        elapsed = now - self.started
        if elapsed >= 300 or (not has_text and elapsed >= 45):
            return 'timeout'
        if not has_text and elapsed >= 8 and not self.notified:
            self.notified = True
            return 'waiting'
        return None


class Host:
    def __init__(self, relay, map_, runtime_factory=None):
        self.relay, self.map = relay, map_
        self.factory = runtime_factory or load(config.RUNTIME)
        self.custom_factory = runtime_factory is not None
        self.model_id = None
        self.models = []
        self.speech = None
        self.stream = Stream()
        self.session = None
        self.active = None
        self.memory_work = None
        self.stopping = asyncio.Event()
        self.ready = asyncio.Event()
        self.wake = asyncio.Event()
        self.relay_lock = asyncio.Lock()
        self.day_lock = asyncio.Lock()
        self.day = None

    async def call(self, method, *args):
        # Relay I/O has its own connection and does not block token delivery.
        async with self.relay_lock:
            return await asyncio.to_thread(method, *args)

    async def refresh_day(self):
        async with self.day_lock:
            day = await self.call(self.relay.day)
            if day != self.day:
                await self.call(self.relay.publish_day, day)
                self.day = day

    async def before_tool(self):
        # Independent connection: do not race the relay connection's transactions.
        valid = self.map.value("select exists(select 1 from assistant.host h,assistant.turns t"
                               " where h.worker_id=%s and h.lease_until>clock_timestamp() and t.id=%s"
                               " and t.worker_id=h.worker_id and t.status='running' and not t.cancel_requested)",
                               (self.relay.worker_id, self.active))
        if not valid:
            raise RuntimeError('This turn is no longer active. Do not perform another action.')

    async def flush(self):
        self.stream.changed.clear()
        if self.stream.pending:
            batch, self.stream.pending = self.stream.pending, []
            await self.call(self.relay.publish, self.active, batch)

    async def prepare_session(self, model=None, mode="talk"):
        if mode == "morning":
            await self.close_session()
        if config.RUNTIME == 'codex' and model == 'codex/' + os.environ.get('ASSISTANT_OPENAI_MODEL', ''):
            model = None
        if self.session and (self.session.conv.cutoff() > self.session.seen_message or model != self.model_id):
            await self.close_session()
        if self.session is None:
            opened = time.monotonic()
            choice = next((m for m in self.models if m['id'] == model), None)
            if model and not choice and not self.custom_factory:
                raise RuntimeError('The selected model is no longer available on this host.')
            runtime = load(choice['runtime'])(model=choice['model']) if choice else self.factory()
            self.model_id = model
            self.session = Session(self.map, runtime, self.stream, 'cloud',
                                   auto_memory=False, before_tool=self.before_tool, spotify_control=self.spotify_control)
            await self.session.open(mode, begin_morning=False)
            self.stream.timing('session_open_seconds', time.monotonic() - opened)

    async def spotify_control(self, args):
        from engine.integrations.spotify import phone_control
        return await phone_control(self, args)

    async def answer(self, turn):
        await self.prepare_session(turn.get('model'), turn.get('mode', 'talk'))
        extra = ("Reply mode: live voice. Speak naturally in plain sentences, with a short complete opening thought. "
                 "No headings, tables, Markdown or spoken URLs. Keep the requested substance."
                 if turn.get('speech') else "Reply mode: written chat. Use natural paragraphs; add structure only where useful.")
        if turn.get('notification'):
            from engine.notifications import discussion_context
            extra += '\n\n' + discussion_context(self.map,turn['notification'])
        if turn.get('mode') == 'morning':
            from engine.morning import prepare
            extra += "\n\n" + await prepare(self.stream)
        await self.session.send(turn['text'], extra_context=extra, **({'images':turn['images']} if turn.get('images') else {}))

    async def interrupt(self, task):
        if self.session:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(self.session.runtime.interrupt(), 3)
        if not task.done():
            task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await task

    async def close_session(self):
        if self.session:
            session, self.session = self.session, None
            await session.close()

    async def process(self, turn):
        self.stream.timings = {}
        self.active = turn['id']
        if self.speech:
            await self.speech.begin(turn)
            self.stream.audio = self.speech.feed if turn.get('speech') else None
        task = asyncio.create_task(self.answer(turn))
        task.add_done_callback(lambda _: self.stream.changed.set())
        status = 'completed'
        heartbeat = asyncio.get_running_loop().time()
        checked_cancel = 0
        deadline = ReplyDeadline(heartbeat)
        try:
            while not task.done():
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(self.stream.changed.wait(), .15)
                await self.flush()
                now = asyncio.get_running_loop().time()
                cancelled = self.stopping.is_set()
                # Token bursts must not each pay for another database round trip.
                # Publication and tool execution still check the active lease.
                if not cancelled and now - checked_cancel >= .25:
                    cancelled = await self.call(self.relay.cancelled, self.active)
                    checked_cancel = asyncio.get_running_loop().time()
                if cancelled:
                    status = 'cancelled'
                    await self.interrupt(task)
                    break
                state = deadline.check(now, 'model_first_text_seconds' in self.stream.timings)
                if state == 'waiting':
                    self.stream.note('Still waiting for the reply. You can stop this request, then retry or choose another model.')
                elif state == 'timeout' and not task.done():
                    status = 'failed'
                    self.stream.timings['reply_deadline_exceeded'] = 1
                    await self.interrupt(task)
                    self.stream.pending.append({'type': 'error', 'message':
                        'The reply took too long and was stopped. Your message is saved. Try again or choose another model; check any requested action before retrying.'})
                    break
                if asyncio.get_running_loop().time() - heartbeat >= 20:
                    await self.call(self.relay.heartbeat)
                    heartbeat = asyncio.get_running_loop().time()
            if status == 'completed':
                try:
                    await task
                except Exception as error:
                    status = 'failed'
                    # Exception text may contain private tool/model data; record only a bounded category.
                    self.stream.timings['runtime_timeout'] = int(isinstance(error, TimeoutError))
                    self.stream.pending.append({'type': 'error', 'message':
                        'The reply could not finish. Your message is saved. Try again or choose another model; check any requested action before retrying.'})
            if self.speech:
                self.speech.finish(status)
            self.stream.timing('reply_total_seconds', asyncio.get_running_loop().time() - deadline.started)
            self.stream.pending.append({'type': 'timing', **self.stream.timings})
            await self.flush()
            await self.refresh_day()
            await self.call(self.relay.finish, self.active, status)
        finally:
            if not task.done():
                await self.interrupt(task)
            await asyncio.gather(task, return_exceptions=True)
            if status != 'completed' or self.stopping.is_set():
                await self.close_session()
            self.active = None
            print('Reply timing: ' + json.dumps(self.stream.timings), flush=True)

    async def run(self):
        acquired = False
        try:
            while not self.stopping.is_set():
                acquired = await self.call(self.relay.acquire)
                if acquired:
                    break
                await asyncio.sleep(2)
            if not acquired:
                return
            from engine.models import available
            from engine.speech import Speech
            self.models = await available()
            self.speech = Speech(self)
            speech_ready = await self.speech.start()
            # Opening a harness does not generate a reply or consume an inference turn.
            model = self.map.value('select model from assistant.turns order by created_at desc limit 1')
            try:
                await self.prepare_session(model)
            except Exception as error:
                await self.close_session()
                print(f'Session preload unavailable ({type(error).__name__}).', flush=True)
            from engine.voice.catalog import choices
            await self.call(self.relay.capabilities, {'models': self.models, 'speech': speech_ready, 'voices': choices() if speech_ready else []})
            print('Host connected.', flush=True)
            await self.refresh_day()
            self.ready.set()
            heartbeat = 0
            while not self.stopping.is_set():
                if asyncio.get_running_loop().time() - heartbeat >= 20:
                    await self.call(self.relay.heartbeat)
                    await self.refresh_day()
                    if self.speech and self.speech.storage:
                        with contextlib.suppress(Exception): await self.speech.cleanup()
                    heartbeat = asyncio.get_running_loop().time()
                self.wake.clear()
                turn = await self.call(self.relay.claim)
                if turn:
                    await self.process(turn)
                else:
                    with contextlib.suppress(asyncio.TimeoutError):
                        await asyncio.wait_for(self.wake.wait(), 10)
        finally:
            await self.close_session()
            if self.speech: await self.speech.close()
            if acquired:
                with contextlib.suppress(Exception):
                    await self.call(self.relay.release)


async def commands(url, host):
    # A separate connection wakes idle workers immediately without frequent polling.
    while not host.stopping.is_set():
        try:
            async with await psycopg.AsyncConnection.connect(url, autocommit=True) as connection:
                await connection.execute('listen assistant_commands')
                async for _ in connection.notifies():
                    host.wake.set()
        except Exception:
            await asyncio.sleep(2)


async def memory_loop(url, host):
    await host.ready.wait()
    map_ = Map(url)
    try:
        from engine.background import Background
        background = Background(map_)
        worker = MemoryWorker(map_)
        while not host.stopping.is_set():
            def idle():
                return host.active is None and (not host.speech or not host.speech.task or host.speech.task.done())
            async def maintain():
                await worker.drain(on_processed=host.refresh_day, can_process=lambda: not host.stopping.is_set())
                if idle(): await background.nightly()
            host.memory_work = asyncio.create_task(maintain())
            try:
                await host.memory_work
            except asyncio.CancelledError:
                if host.stopping.is_set(): raise
            finally:
                host.memory_work = None
            try:
                await asyncio.wait_for(host.stopping.wait(), 10)
            except asyncio.TimeoutError:
                pass
    finally:
        map_.close()


async def supervise(host, services):
    workers = [asyncio.create_task(work, name=name) for name, work in services.items()]
    running = asyncio.create_task(host.run(), name='conversation')
    try:
        done, _ = await asyncio.wait([running, *workers], return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
        if not host.stopping.is_set():
            raise RuntimeError(f'{next(iter(done)).get_name()} stopped unexpectedly.')
    finally:
        host.stopping.set()
        for task in workers:
            task.cancel()
        # Let an active reply cancel and release its lease before closing the maps.
        with contextlib.suppress(Exception, asyncio.CancelledError):
            await asyncio.wait_for(running, 10)
        await asyncio.gather(running, *workers, return_exceptions=True)


async def main():
    from engine.integrations.email import run as send_mail
    from engine.background import gather_sources, classify_mail
    from engine.notifications import run as notify
    from engine.jobs import run as run_jobs
    from engine.developer import run as run_developer
    from engine.attention import run as run_attention

    with contextlib.ExitStack() as resources:
        relay_map = resources.enter_context(contextlib.closing(Map()))
        session_map = resources.enter_context(contextlib.closing(Map()))
        for map_ in (relay_map, session_map):
            map_.execute("set statement_timeout='15s'")
            map_.execute("set lock_timeout='5s'")
        host = Host(Relay(relay_map), session_map)
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, host.stopping.set)
            resources.callback(loop.remove_signal_handler, sig)
        await supervise(host, {
            'commands': commands(relay_map.url, host),
            'sources': gather_sources(relay_map.url, host),
            'mail': classify_mail(relay_map.url, host),
            'email_sender': send_mail(relay_map.url, host),
            'notifications': notify(relay_map.url, host),
            'jobs': run_jobs(relay_map.url, host),
            'development': run_developer(relay_map.url, host),
            'attention': run_attention(relay_map.url, host),
            'memory': memory_loop(relay_map.url, host),
        })


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as error:
        # Connection strings and model responses must not become deployment logs.
        print(f'Host stopped ({type(error).__name__}).', flush=True)
        raise SystemExit(1) from None
