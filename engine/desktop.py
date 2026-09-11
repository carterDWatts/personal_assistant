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
    def input_saved(self, images): emit("images_saved", images=images)
    def start_turn(self): emit("start")
    def delta(self, text): emit("delta", text=text)
    def replace_text(self, text): emit("replace", text=text)
    def end_turn(self): emit("end")
    def note(self, text): emit("status", text=text)
    def tool_result(self, payload):
        from engine.integrations.google import CONNECTION_ACTIONS
        from engine.integrations.services import CONNECTION_ACTIONS as SERVICE_ACTIONS
        try:
            data = json.loads(payload.get("content", ""))
        except (ValueError, TypeError):
            return
        if isinstance(data,dict) and data.get('image',{}).get('id'):
            emit('image',image=data['image'],caption=data.get('caption',''))
        if isinstance(data,dict) and data.get('needs_review') and data.get('draft',{}).get('id'):
            emit('email_draft',draft_id=data['draft']['id'])
        if payload.get("is_error") and isinstance(data, dict) and data.get("connection_action") in CONNECTION_ACTIONS | SERVICE_ACTIONS:
            emit("connection_required", action=data["connection_action"], **{k:data[k] for k in ("session_id", "provider") if data.get(k)})
    def close(self): pass


async def main():
    load_settings()
    from engine import config
    from engine.db import Map
    from engine.engine import Session
    from engine.runtime import load
    from engine.jobs import run as run_jobs
    from engine.integrations import google, services
    from engine.integrations.catalog import ACCOUNT_PROVIDERS, OAUTH_PROVIDERS
    map_, session, active, memory_poll = None, None, None, None
    connection_task = None
    outbound_cursor = 0
    jobs_task = None
    email_task = None

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
                 error="Sign-in wasn’t completed. Please try again." if provider in OAUTH_PROVIDERS else "Could not connect. Check the token and its permissions.")

    async def google_action(action, connection):
        emit("connections", **(await connection_status()), connecting=True)
        try:
            await asyncio.to_thread(google.disconnect if action == "google_disconnect" else google.connect, connection)
            emit("connections", **(await connection_status()), connecting=False, completed=action != "google_disconnect", action=connection)
        except Exception:
            emit("connections", **(await connection_status()), connecting=False,
                 error="Google wasn’t connected. Try again and approve the requested access.")

    async def monitor_memory():
        nonlocal outbound_cursor
        cancelled = set()
        while True:
            try:
                rows = map_.rows("select m.id,m.role,m.content,m.created_at,m.payload from memory.messages m where m.id>%s and (m.payload ? 'inbox_source_id' or coalesce((m.payload->>'proactive')::boolean,false)) order by m.id", (outbound_cursor,))
                for row in rows:
                    emit("inbox_opened" if (row.get("payload") or {}).get("inbox_source_id") else "proactive", message=row)
                    outbound_cursor=row['id']
                for row in map_.rows("select message_id from assistant.inbox_cancellations where message_id>(select coalesce(max(id),0) from memory.messages where payload->>'event'='chat_cleared')"):
                    if row['message_id'] not in cancelled:
                        emit('inbox_cancelled',message_id=str(row['message_id']))
                        cancelled.add(row['message_id'])
                counts = map_.row("select count(*) filter(where status <> 'done') as pending, count(*) filter(where status='error') as errors from memory.memory_jobs")
                text = "Memory update paused; chat still works." if counts['errors'] else "Updating memory in the background…" if counts['pending'] else ""
                emit("memory", text=text)
                emit("map",
                     calendar=map_.value("select payload || jsonb_build_object('error',last_error) from assistant.source_items where source='calendar-view' and id='current'") or {},
                     plans=map_.rows("select * from memory.plan_notes(current_date)"),
                     questions=map_.value("select count(*) from memory.questions where closed_at is null"),
                     pending=counts['pending'], errors=counts['errors'])
            except Exception:
                emit("memory", text="Memory status is unavailable.")
            await asyncio.sleep(3)

    interrupted = False

    async def reply(text, reference=None, images=None):
        nonlocal interrupted
        interrupted = False
        try:
            from engine.notifications import discussion_context
            await session.send(text, extra_context=discussion_context(map_,reference) if reference else "",images=images)
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
                        if provider not in ACCOUNT_PROVIDERS:
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
                elif action == 'image' and map_:
                    from engine.images import Images
                    import base64
                    try:
                        args=message.get('args',{})
                        images=Images(map_)
                        if args.get('operation')=='upload':
                            result=await asyncio.to_thread(images.save,base64.b64decode(args['data'],validate=True),args.get('name','Image'),None,args.get('id'))
                        elif args.get('operation')=='get':
                            result=await asyncio.to_thread(images.preview,args['id'])
                        else: raise ValueError('Invalid image operation')
                        emit('client_response',request_id=message.get('request_id'),result=result)
                    except Exception:
                        emit('client_response',request_id=message.get('request_id'),error='The image could not be loaded. Try a smaller image.')
                elif action in ('inbox','inbox_open','inbox_cancel') and map_:
                    from engine.client import inbox_request
                    try:
                        result=inbox_request(map_,action,message.get('args',{}))
                        emit('client_response',request_id=message.get('request_id'),result=result)
                    except Exception:
                        emit('client_response',request_id=message.get('request_id'),error='The message could not be opened. Try again.')
                elif action == 'email' and map_:
                    from engine.client import email_request
                    try:
                        result=email_request(map_,message.get('args',{}))
                        emit('client_response',request_id=message.get('request_id'),result=result)
                    except Exception:
                        emit('client_response',request_id=message.get('request_id'),error='The draft changed or is unavailable. Review it again.')
                elif action == "connect":
                    if session:
                        raise ValueError("Already connected")
                    name = message.get("runtime", "claude-agent-sdk")
                    runtime = load(name)()
                    map_ = Map()
                    async def spotify_control(args):
                        from engine.integrations.spotify_mac import control
                        emit('spotify_control', action=args['action'])
                        return await control(args)
                    session = Session(map_, runtime, DesktopIO(), config.DEVICE, spotify_control=spotify_control)
                    clear = message.get("clear") is True
                    outbound_cursor = map_.value("select coalesce(max(message_id),0) from assistant.outbound")
                    emit("history", messages=[] if clear else session.conv.tail(100))
                    await session.open("clear" if clear else "talk")
                    emit("ready")
                    memory_poll = asyncio.create_task(monitor_memory())
                    jobs_task = asyncio.create_task(run_jobs(map_.url))
                    from engine.integrations.email import run as send_mail
                    email_task = asyncio.create_task(send_mail(map_.url))
                elif action == "send" and session:
                    if active and not active.done():
                        raise ValueError("Wait for the current reply")
                    text = message.get("text", "").strip()
                    if text:
                        active = asyncio.create_task(reply(text, message.get("notification"), message.get("images")))
                elif action == "stop" and session:
                    interrupted = bool(active and not active.done())
                    if not interrupted:
                        continue
                    await session.runtime.interrupt()
                elif action == "quit":
                    break
            except RuntimeError as error:
                emit("error", text=str(error))
            except Exception:
                emit("error", text="Could not connect. Check your database setting and subscription login, then reconnect.")
    finally:
        tasks = [task for task in (email_task, jobs_task, memory_poll, active, connection_task) if task]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        try:
            if session: await session.close()
        finally:
            if map_: map_.close()


if __name__ == "__main__":
    asyncio.run(main())
