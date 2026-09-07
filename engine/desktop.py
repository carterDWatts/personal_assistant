"""Private JSON-lines bridge for the native Mac application. No listening socket."""
import asyncio
import json
import os
import shlex
import sys
from pathlib import Path


def load_settings():
    # Finder does not inherit terminal exports. Parse literal settings, never execute shell code.
    allowed = {"ASSISTANT_DATABASE_URL", "ASSISTANT_TEST_DATABASE_URL", "ASSISTANT_TIMEZONE", "ASSISTANT_MODEL", "ASSISTANT_OPENAI_MODEL"}
    path = Path.home() / ".zshrc"
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                words = shlex.split(line, comments=True)
            except ValueError:
                continue
            if len(words) == 2 and words[0] == "export" and "=" in words[1]:
                key, value = words[1].split("=", 1)
                literal = line.split("=", 1)[1].lstrip().startswith("'")
                if key in allowed and (literal or not any(c in value for c in ("$", "`"))):
                    os.environ.setdefault(key, value)


def emit(kind, **values):
    print(json.dumps({"type": kind, **values}, default=str), flush=True)


class DesktopIO:
    def start_turn(self): emit("start")
    def delta(self, text): emit("delta", text=text)
    def replace_text(self, text): emit("replace", text=text)
    def end_turn(self): emit("end")
    def note(self, text): emit("status", text=text)
    def close(self): pass


async def main():
    load_settings()
    from engine import config
    from engine.db import Map
    from engine.engine import Session
    from engine.runtime import load
    map_, session, active, memory_poll = None, None, None, None
    async def monitor_memory():
        while True:
            try:
                counts = map_.row("select count(*) filter(where status <> 'done') as pending, count(*) filter(where status='error') as errors from memory.memory_jobs")
                text = "Memory update paused; chat still works." if counts['errors'] else "Updating memory in the background…" if counts['pending'] else ""
                emit("memory", text=text)
            except Exception:
                emit("memory", text="Memory status is unavailable.")
            await asyncio.sleep(3)

    interrupted = False

    async def reply(text):
        nonlocal interrupted
        interrupted = False
        try:
            await session.send(text)
        except RuntimeError as error:
            if interrupted:
                emit("ready")
            else:
                emit("error", text=str(error))
        except Exception:
            emit("error", text="The reply failed. Previously saved messages are available; reconnect to continue.")
        else:
            emit("ready")
    try:
        while line := await asyncio.to_thread(sys.stdin.readline):
            try:
                message = json.loads(line)
                action = message.get("type")
                if action == "connect":
                    if session:
                        raise ValueError("Already connected")
                    name = message.get("runtime", "claude-agent-sdk")
                    runtime = load(name)()
                    map_ = Map()
                    session = Session(map_, runtime, DesktopIO(), config.DEVICE)
                    clear = message.get("clear") is True
                    emit("history", messages=[] if clear else session.conv.tail(100))
                    await session.open("clear" if clear else "talk")
                    emit("ready")
                    memory_poll = asyncio.create_task(monitor_memory())
                elif action == "send" and session:
                    if active and not active.done():
                        raise ValueError("Wait for the current reply")
                    text = message.get("text", "").strip()
                    if text:
                        active = asyncio.create_task(reply(text))
                elif action == "stop" and session:
                    interrupted = bool(active and not active.done())
                    if not interrupted:
                        continue
                    interrupt = getattr(session.runtime, "interrupt", None)
                    if interrupt:
                        await interrupt()
                    elif getattr(session.runtime, "client", None):
                        await session.runtime.client.interrupt()
                elif action == "quit":
                    break
            except RuntimeError as error:
                emit("error", text=str(error))
            except Exception:
                emit("error", text="Could not connect. Check your database setting and subscription login, then reconnect.")
    finally:
        if memory_poll:
            memory_poll.cancel()
            await asyncio.gather(memory_poll, return_exceptions=True)
        if active and not active.done():
            active.cancel()
            await asyncio.gather(active, return_exceptions=True)
        if session:
            await session.close()
        if map_:
            map_.close()


if __name__ == "__main__":
    asyncio.run(main())
