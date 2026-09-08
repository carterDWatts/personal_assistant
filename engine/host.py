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
        if not payload.get('is_error'):
            return
        try:
            result = json.loads(payload.get('content', ''))
        except (ValueError, TypeError):
            return
        if isinstance(result, dict) and result.get('connection_action') in CONNECTION_ACTIONS | SERVICE_ACTIONS:
            self.pending.append({'type': 'connection_required', 'action': result['connection_action'],
                                 'message': 'This service needs to be connected on this host.'})

    def end_turn(self):
        pass  # Terminal status belongs to the worker, including cancellation.

    def close(self):
        pass


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

    async def prepare_session(self, model=None):
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
                                   auto_memory=False, before_tool=self.before_tool)
            await self.session.open()
            self.stream.timing('session_open_seconds', time.monotonic() - opened)

    async def answer(self, turn):
        await self.prepare_session(turn.get('model'))
        await self.session.send(turn['text'])

    async def interrupt(self, task):
        runtime = self.session.runtime if self.session else None
        interrupt = getattr(runtime, 'interrupt', None)
        if not interrupt and getattr(runtime, 'client', None):
            interrupt = runtime.client.interrupt
        if interrupt:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(interrupt(), 3)
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
        if self.memory_work and not self.memory_work.done():
            self.memory_work.cancel()
        self.active = turn['id']
        if self.speech:
            await self.speech.begin(turn)
            self.stream.audio = self.speech.feed if turn.get('speech') else None
        task = asyncio.create_task(self.answer(turn))
        task.add_done_callback(lambda _: self.stream.changed.set())
        status = 'completed'
        heartbeat = asyncio.get_running_loop().time()
        checked_cancel = 0
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
                if asyncio.get_running_loop().time() - heartbeat >= 20:
                    await self.call(self.relay.heartbeat)
                    heartbeat = asyncio.get_running_loop().time()
            if status != 'cancelled':
                try:
                    await task
                except Exception:
                    status = 'failed'
                    self.stream.pending.append({'type': 'error', 'message':
                        'The subscription runtime could not finish. Check the host login or usage limit before retrying.'})
            if self.speech:
                self.speech.finish(status)
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
            await self.call(self.relay.capabilities, {'models': self.models, 'speech': speech_ready})
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
        worker = MemoryWorker(map_)
        while not host.stopping.is_set():
            def idle():
                return host.active is None and (not host.speech or not host.speech.task or host.speech.task.done())
            if idle():
                host.memory_work = asyncio.create_task(worker.drain(on_processed=host.refresh_day, can_process=idle))
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


async def main():
    relay_map, session_map = Map(), Map()
    for map_ in (relay_map, session_map):
        map_.execute("set statement_timeout='15s'")
        map_.execute("set lock_timeout='5s'")
    host = Host(Relay(relay_map), session_map)
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, host.stopping.set)
    listener = asyncio.create_task(commands(relay_map.url, host))
    memory = asyncio.create_task(memory_loop(relay_map.url, host))
    running = asyncio.create_task(host.run())
    try:
        done, _ = await asyncio.wait((running, memory), return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        host.stopping.set()
        memory.cancel()
        listener.cancel()
        with contextlib.suppress(Exception, asyncio.CancelledError):
            await asyncio.wait_for(running, 10)
        await asyncio.gather(memory, listener, return_exceptions=True)
        relay_map.close()
        session_map.close()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except Exception as error:
        # Connection strings and model responses must not become deployment logs.
        print(f'Host stopped ({type(error).__name__}).', flush=True)
        raise SystemExit(1) from None
