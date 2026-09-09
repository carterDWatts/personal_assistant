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
    def tool_result(self, payload):
        from engine.integrations.google import CONNECTION_ACTIONS
        from engine.integrations.services import CONNECTION_ACTIONS as SERVICE_ACTIONS
        if not payload.get("is_error"):
            return
        try:
            data = json.loads(payload.get("content", ""))
        except (ValueError, TypeError):
            return
        if isinstance(data, dict) and data.get("connection_action") in CONNECTION_ACTIONS | SERVICE_ACTIONS | {'browser_connect'}:
            emit("connection_required", action=data["connection_action"], **{k:data[k] for k in ("session_id", "provider") if data.get(k)})
    def close(self): pass


async def main():
    load_settings()
    from engine import config
    from engine.db import Map
    from engine.engine import Session
    from engine.runtime import load
    from engine.integrations import google, services
    map_, session, active, memory_poll = None, None, None, None
    connection_task = None
    outbound_cursor = 0
    jobs_task = None

    async def connection_status():
        google_status, service_status = await asyncio.gather(asyncio.to_thread(google.status), asyncio.to_thread(services.status))
        return {**google_status, "services": service_status}

    async def service_action(action, provider, token=None):
        emit("connections", **(await connection_status()), connecting=True)
        try:
            if action == "service_disconnect":
                await asyncio.to_thread(services.disconnect, provider)
            else:
                await asyncio.to_thread(services.connect, provider, token)
            emit("connections", **(await connection_status()), connecting=False,
                 completed=action == "service_connect", action=f"{provider}_connect")
        except Exception:
            emit("connections", **(await connection_status()), connecting=False,
                 error="Sign-in wasn’t completed. Please try again." if provider in ('github','supabase') else "Could not connect. Check the token and its permissions.")

    async def google_action(action, connection):
        emit("connections", **(await connection_status()), connecting=True)
        try:
            await asyncio.to_thread(google.disconnect if action == "google_disconnect" else google.connect, connection)
            emit("connections", **(await connection_status()), connecting=False, completed=action != "google_disconnect", action=connection)
        except Exception:
            emit("connections", **(await connection_status()), connecting=False,
                 error="Google wasn’t connected. Try again and approve the requested access.")

    async def local_jobs():
        from engine.jobs import Worker
        jobs_map = Map()
        try:
            worker = Worker(jobs_map)
            while True:
                # The hosted worker owns production jobs while it is online.
                if not jobs_map.value('select exists(select 1 from assistant.host where lease_until>now())'):
                    await worker.once()
                await asyncio.sleep(3)
        finally:
            jobs_map.close()

    async def monitor_memory():
        nonlocal outbound_cursor
        while True:
            try:
                rows = map_.rows("select m.id,m.role,m.content,m.created_at,m.payload from assistant.outbound o join memory.messages m on m.id=o.message_id where m.id>%s order by m.id", (outbound_cursor,))
                for row in rows:
                    emit("proactive", message=row)
                    outbound_cursor=row['id']
                counts = map_.row("select count(*) filter(where status <> 'done') as pending, count(*) filter(where status='error') as errors from memory.memory_jobs")
                text = "Memory update paused; chat still works." if counts['errors'] else "Updating memory in the background…" if counts['pending'] else ""
                emit("memory", text=text)
                # What the memory panel shows: the latest things learned, today's plan, and what is still open.
                emit("map",
                     calendar=map_.value("select payload || jsonb_build_object('error',last_error) from assistant.source_items where source='calendar-view' and id='current'") or {},
                     learned=map_.rows("select entity_name, attribute, value, recorded_at from memory.current_assertions"
                                       " order by recorded_at desc limit 8"),
                     plans=map_.rows("select item, status from memory.plans where day = current_date order by id"),
                     questions=map_.value("select count(*) from memory.questions where closed_at is null"),
                     pending=counts['pending'], errors=counts['errors'])
            except Exception:
                emit("memory", text="Memory status is unavailable.")
            await asyncio.sleep(3)

    interrupted = False

    async def reply(text, reference=None):
        nonlocal interrupted
        interrupted = False
        try:
            from engine.notifications import discussion_context
            await session.send(text, extra_context=discussion_context(map_,reference) if reference else "")
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
                if action == "connections":
                    emit("connections", **(await connection_status()),
                         connecting=bool(connection_task and not connection_task.done()))
                elif action in google.CONNECTION_ACTIONS or action == "google_disconnect":
                    if not connection_task or connection_task.done():
                        connection_task = asyncio.create_task(google_action(action, message.get("connection", "google_connect") if action == "google_disconnect" else action))
                elif action in ("service_connect", "service_disconnect"):
                    if not connection_task or connection_task.done():
                        # Credentials travel through this private pipe, never through Session.send or emit.
                        provider, token = message.get("provider"), message.pop("token", None)
                        if provider not in services.PROVIDERS:
                            raise ValueError("Unknown connection")
                        connection_task = asyncio.create_task(service_action(action, provider, token))
                        token = None
                elif action in ("import_part", "imports") and map_:
                    from engine.db import jsonb
                    try:
                        if action == "import_part":
                            result = map_.value("select memory.import_part(%s)", (jsonb(message["args"]),))
                            from engine.memory_worker import kick
                            kick(message["args"]["runtime"])
                        else:
                            result = {"imports": map_.value("select memory.import_status()")}
                        emit("imports", request_id=message.get("request_id"), **result)
                    except Exception:
                        emit("imports", request_id=message.get("request_id"), error="The import was not saved. Retry with the same text.")
                elif action == "browser_request" and map_:
                    from engine.browser.crypto import seal
                    from engine.db import jsonb
                    import uuid
                    try:
                        operation=message['action'];args=message.get('args',{})
                        if operation=='browser_command':
                            public=map_.value("select public_key from assistant.browser_host where seen_at>now()-interval '60 seconds'")
                            if not public:raise ValueError('Browser unavailable')
                            args={"session_id":args['session_id'],"id":args['id'],"encrypted":seal(public,args['command'],args['id'])}
                        # Local owner bridge has the same private DB authority as the Mac session.
                        owner=map_.value('select user_id from assistant.owner')
                        device=map_.value("select id from assistant.devices where user_id=%s and name='Mac browser bridge' and revoked_at is null limit 1",(owner,))
                        if not device:
                            device=str(uuid.uuid4());map_.execute("insert into assistant.devices(id,user_id,name) values(%s,%s,'Mac browser bridge')",(device,owner))
                        result=map_.value('select public.assistant_browser(%s,%s,%s,%s)',(owner,device,operation,jsonb(args)))
                        emit('browser_result',request_id=message['request_id'],result=result)
                    except Exception:emit('browser_result',request_id=message['request_id'],error='Browser access is unavailable.')
                elif action == "connect":
                    if session:
                        raise ValueError("Already connected")
                    name = message.get("runtime", "claude-agent-sdk")
                    runtime = load(name)()
                    map_ = Map()
                    session = Session(map_, runtime, DesktopIO(), config.DEVICE)
                    clear = message.get("clear") is True
                    outbound_cursor = map_.value("select coalesce(max(message_id),0) from assistant.outbound")
                    emit("history", messages=[] if clear else session.conv.tail(100))
                    await session.open("clear" if clear else "talk")
                    emit("ready")
                    memory_poll = asyncio.create_task(monitor_memory())
                    jobs_task = asyncio.create_task(local_jobs())
                elif action == "send" and session:
                    if active and not active.done():
                        raise ValueError("Wait for the current reply")
                    text = message.get("text", "").strip()
                    if text:
                        active = asyncio.create_task(reply(text, message.get("notification")))
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
        if jobs_task:
            jobs_task.cancel()
            await asyncio.gather(jobs_task, return_exceptions=True)
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
