"""The engine: joins the conversation, runs turns, mirrors everything to the map."""

from engine import context
from engine.config import prompt
from engine.conversation import Conversation
from engine.tools import Tools


async def run(mode, map_, runtime, io, device):
    conv = Conversation(map_, device, runtime.name)
    tools = Tools(map_, device)
    segment_id, resume, seed = conv.resolve(mode)

    system = prompt("persona")
    if mode == "morning":
        system += "\n\n" + prompt("morning")
    await runtime.open(system, tools.specs(), resume=resume)

    opening = None
    if resume is None:
        opening = context.snapshot(map_)
        if seed:
            opening += "\n\n" + seed
        conv.record(segment_id, "system", opening, {"kind": "opening"})

    ended_by = "user"
    try:
        if mode == "morning":
            mid = conv.record(segment_id, "system", "Begin the morning session.", {"kind": "morning"})
            await turn(runtime, conv, tools, io, segment_id, mid, f"{opening}\n\nBegin the morning session.")
            opening = None
        while True:
            text = io.read()
            if text is None:
                break
            if not text.strip():
                continue
            mid = conv.record(segment_id, "user", text)
            sent = f"{opening}\n\nThe user says:\n{text}" if opening else text
            opening = None
            await turn(runtime, conv, tools, io, segment_id, mid, sent)
    except KeyboardInterrupt:
        io.end_turn()
    finally:
        metrics = await runtime.close()
        if runtime.session_id:
            conv.set_runtime_session(segment_id, runtime.session_id)
        conv.close_segment(segment_id, ended_by, metrics.as_dict())
        io.note(f"this session: ${metrics.cost_usd:.3f}, {metrics.turns} turns, "
                f"{metrics.cache_read_tokens} cached in, {metrics.cache_write_tokens} written, {metrics.output_tokens} out")
        io.close()


async def turn(runtime, conv, tools, io, segment_id, message_id, text):
    tools.message_id = message_id
    streamed = False
    texts = []
    io.start_turn()
    async for ev in runtime.send(text):
        if ev.kind == "text":
            streamed = True
            io.delta(ev.text)
        elif ev.kind == "assistant_text":
            texts.append(ev.text)
            if not streamed:
                io.delta(ev.text)
            streamed = False
        elif ev.kind == "tool_use":
            io.note(ev.name)
            conv.record(segment_id, "tool", None, {"call": ev.name, "input": ev.payload})
        elif ev.kind == "tool_result":
            conv.record(segment_id, "tool", None, {"result_for": ev.name, **(ev.payload or {})})
        elif ev.kind == "done":
            io.end_turn()
            if ev.payload:
                io.note(f"${ev.payload['cost_usd']:.3f}")
    if texts:
        conv.record(segment_id, "assistant", "\n\n".join(texts))
    if runtime.session_id:
        conv.set_runtime_session(segment_id, runtime.session_id)
