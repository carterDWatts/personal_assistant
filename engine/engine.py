"""Conversation lifecycle shared by terminal and desktop clients."""

import time
from engine import config, context
from engine.config import prompt
from engine.conversation import Conversation
from engine.tools import Tools
from engine.runtime import Metrics
from engine import memory_worker


class Session:
    def __init__(self, map_, runtime, io, device, *, auto_memory=True, before_tool=None, spotify_control=None):
        self.map, self.runtime, self.io = map_, runtime, io
        self.conv = Conversation(map_, device, runtime.name)
        self.tools = Tools(map_, device)
        self.tools.runtime_name = runtime.name
        self.tools.model = getattr(runtime, "model", None)
        self.segment_id = None
        self.seed = None
        self.ended_by = "user"
        self.seen_message = 0
        self.locked = False
        self.auto_memory = auto_memory
        self.before_tool = before_tool
        self.spotify_control = spotify_control
        self.sent_snapshot = None
        self.context_revision = 0
        self.prepared = context.PreparedContext(map_)
        self.morning = False
        self.routine_id = None

    async def open(self, mode="talk", *, begin_morning=True):
        self.segment_id, resume, self.seed = self.conv.resolve(mode)
        from engine.routine import active
        self.routine_id = self.segment_id if mode in ('morning','review') else active(self.map)
        self.morning = self.routine_id is not None
        self.locked = bool(self.map.value("select pg_try_advisory_lock(hashtextextended(%s, 0))", ("conversation:" + str(self.segment_id),)))
        if not self.locked:
            self.segment_id = None
            raise RuntimeError("This conversation is already open on this Mac. Disconnect the other window first.")
        self.seen_message = self.map.value("select coalesce(max(id),0) from memory.messages")
        system = prompt("persona")
        if self.morning:
            kind=self.map.value('select agent from memory.conversations where id=%s',(self.routine_id,))
            system += "\n\n" + prompt('review' if kind=='review' else 'morning')
        specs = self.tools.read_specs(self.spotify_control)
        if self.morning:
            from engine.routine import spec
            specs.append(spec(self.tools,self.routine_id))
        if self.before_tool:
            from dataclasses import replace
            def guarded(fn):
                async def call(args):
                    await self.before_tool()
                    return await fn(args)
                return call
            specs = [replace(spec, fn=guarded(spec.fn)) for spec in specs]
        self.system_prompt,self.runtime_specs=system,specs
        await self.runtime.open(system, specs, resume=resume)
        if resume and not getattr(self.runtime, "resumed", True):
            self.seed = self.conv.seed_text(self.conv.tail(30))
        if self.runtime.session_id:
            self.conv.set_runtime_session(self.segment_id, self.runtime.session_id)
        self.prepared.read()
        if self.auto_memory:
            memory_worker.kick(self.runtime.name)
        if mode == "morning" and begin_morning:
            await self.send("Begin the morning session.", role="system")

    async def send(self, text, role="user", *, extra_context="", images=None):
        # Refresh on every turn, including resumed sessions. Model context is a cache.
        started = time.monotonic()
        if callable(getattr(self.runtime,'restart',None)) and (getattr(self.runtime,'needs_reseed',False) or getattr(self.runtime,'context_tokens',0)>90000):
            await self.runtime.restart(self.system_prompt,self.runtime_specs)
            self.seed=self.conv.seed_text(self.conv.tail(config.SEED_MESSAGES))
            self.sent_snapshot=None
            self.conv.set_runtime_session(self.segment_id,self.runtime.session_id)
        sections = self.prepared.read()
        revision = getattr(self.runtime, 'context_revision', 0)
        if revision != self.context_revision:
            self.sent_snapshot = None
        opening = context.update(self.sent_snapshot, sections)
        if self.morning:
            from engine.routine import progress, steer
            from engine.db import dumps
            if role == 'user':
                if self.before_tool:
                    await self.before_tool()
                await steer(self.tools,self.routine_id,text)
            opening += '\n\nRoutine progress (authoritative; resume here, not at the greeting):\n'+dumps(progress(self.map,self.routine_id))
        recent = self.map.rows(
            "select id, role, content, created_at from memory.messages where id > %s and conversation_id <> %s"
            " and role in ('user','assistant') and content is not null order by id limit 100",
            (self.seen_message, self.segment_id))
        if recent:
            opening += "\n\nNew messages from other sessions:\n" + "\n".join(f"{m['role']}: {m['content']}" for m in recent)
            self.seen_message = recent[-1]["id"]
        if self.seed:
            opening += "\n\n" + self.seed
            self.seed = None
        image_ids=[str(id) for id in (images or [])]
        image_content=[]
        if image_ids:
            import asyncio
            from engine.images import Images
            image_content=await asyncio.to_thread(Images(self.map).contents,image_ids)
            opening += '\nAttached image IDs: '+', '.join(image_ids)
        mid = self.conv.record(self.segment_id, role, text, {"images":image_ids} if image_ids else None)
        if image_ids and (saved := getattr(self.io, "input_saved", None)):
            saved(image_ids)
        if timing := getattr(self.io, "timing", None):
            timing("context_seconds", time.monotonic() - started)
        try:
            await turn(self.runtime, self.conv, self.tools, self.io, self.segment_id, mid,
                       f"{opening}\n\n{extra_context}\n\n" + ("The user says:" if role=="user" else "System event (not a user message):") + f"\n{text}", images=image_content)
            self.sent_snapshot = sections if getattr(self.runtime, 'context_revision', 0) == revision else None
            self.context_revision = getattr(self.runtime, 'context_revision', 0)
        except BaseException:
            self.sent_snapshot = None
            self.ended_by = "error"
            raise
        finally:
            if self.auto_memory:
                memory_worker.kick(self.runtime.name)

    async def close(self):
        metrics = getattr(self.runtime, "metrics", Metrics())
        try:
            metrics = await self.runtime.close()
        finally:
            try:
                if self.segment_id:
                    if self.runtime.session_id:
                        self.conv.set_runtime_session(self.segment_id, self.runtime.session_id)
                    self.conv.close_segment(self.segment_id, self.ended_by, metrics.as_dict())
            finally:
                if self.locked:
                    self.map.execute("select pg_advisory_unlock(hashtextextended(%s, 0))", ("conversation:" + str(self.segment_id),))
                    self.locked = False
                self.io.close()


async def run(mode, map_, runtime, io, device):
    session = Session(map_, runtime, io, device)
    try:
        await session.open(mode)
        while (text := io.read()) is not None:
            if text.strip():
                await session.send(text)
    except BaseException:
        session.ended_by = "error"
        raise
    finally:
        await session.close()


async def turn(runtime, conv, tools, io, segment_id, message_id, text, images=None):
    tools.message_id = message_id
    completed, pending = [], ""
    shown_images, email_drafts = [], []
    failed = True
    io.start_turn()
    started = time.monotonic()
    first_text = True
    try:
        events=runtime.send(text, images=images) if images else runtime.send(text)
        async for ev in events:
            if first_text and ev.kind in ("text", "assistant_text") and ev.text:
                first_text = False
                if timing := getattr(io, "timing", None):
                    timing("model_first_text_seconds", time.monotonic() - started)
            if ev.kind == "text":
                pending += ev.text
                io.delta(ev.text)
            elif ev.kind == "assistant_text":
                completed.append(ev.text)
                if not pending:
                    io.delta(ev.text)
                pending = ""
            elif ev.kind == "tool_use":
                io.note(ev.name)
                conv.record(segment_id, "tool", None, {"call": ev.name, "input": ev.payload})
            elif ev.kind == "tool_result":
                import json
                try:
                    receipt=json.loads((ev.payload or {}).get('content',''))
                    if isinstance(receipt,dict) and receipt.get('image',{}).get('id'):
                        shown_images.append(receipt['image']['id'])
                    if isinstance(receipt,dict) and receipt.get('needs_review') and receipt.get('draft',{}).get('id'):
                        email_drafts.append(receipt['draft']['id'])
                except (ValueError,TypeError): pass
                conv.record(segment_id, "tool", None, {"result_for": ev.name, **(ev.payload or {})})
                if notify := getattr(io, "tool_result", None):
                    notify(ev.payload or {})
        failed = False
    finally:
        if pending:
            completed.append(pending)
        if completed or shown_images or email_drafts:
            final_text = "\n\n".join(completed) or ("I’ve prepared the email for your review." if email_drafts else "Image")
            conv.record(segment_id, "assistant", final_text, {"interrupted": failed, "images":list(dict.fromkeys(shown_images)), "email_drafts":list(dict.fromkeys(email_drafts))})
            if replace := getattr(io, "replace_text", None):
                replace(final_text)
        if runtime.session_id:
            conv.set_runtime_session(segment_id, runtime.session_id)
        io.end_turn()
