"""ChatGPT subscription adapter over Codex's local JSON-RPC app server."""

import asyncio
import json
import os
import shutil
from pathlib import Path

from engine import config
from engine.runtime import Event, Metrics
from engine.tools import run


class CodexRequestError(RuntimeError):
    pass


class CodexRuntime:
    name = "codex"

    def __init__(self, executable=None, model=None, effort=None):
        self.model = model or os.environ.get("ASSISTANT_OPENAI_MODEL")
        self.effort = effort or config.EFFORT
        self.executable = executable or os.environ.get("ASSISTANT_CODEX_PATH") or shutil.which("codex") or "/Applications/ChatGPT.app/Contents/Resources/codex"
        self.process = None
        self.session_id = None
        self.resumed = False
        self.turn_id = None
        self.metrics = Metrics()
        self.serial = 0
        self.pending = {}
        self.events = asyncio.Queue()
        self.reader = None
        self.tools = {}
        self.usage_baseline = None
        self.latest_usage = {}

    async def _write(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        await self.process.stdin.drain()

    async def request(self, method, params):
        self.serial += 1
        number = self.serial
        future = asyncio.get_running_loop().create_future()
        self.pending[number] = future
        try:
            await self._write({"id": number, "method": method, "params": params})
            return await asyncio.wait_for(future, 45)
        finally:
            self.pending.pop(number, None)

    async def _read(self):
        try:
            while line := await self.process.stdout.readline():
                message = json.loads(line)
                if "method" not in message and "id" in message:
                    future = self.pending.get(message["id"])
                    if future and not future.done():
                        if "error" in message:
                            future.set_exception(CodexRequestError(str(message["error"].get("message", "Codex rejected the request"))[:600]))
                        else:
                            future.set_result(message.get("result", {}))
                else:
                    await self.events.put(message)
        finally:
            error = RuntimeError("Codex disconnected. Your saved conversation is still available.")
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(error)
            await self.events.put(error)

    async def open(self, system_prompt, tools, resume=None):
        self.tools = {s.name: s for s in tools}
        state = Path.home() / "Library/Application Support/Personal Assistant" / config.ENV / "codex"
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Share the user's login only; do not inherit their plugins, MCP servers or tools.
        login = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "auth.json"
        target = state / "auth.json"
        if login.is_file() and not target.exists():
            target.symlink_to(login)
        environment = {k: v for k, v in os.environ.items() if k in ("HOME", "PATH", "TMPDIR", "LANG", "USER", "LOGNAME")}
        environment["CODEX_HOME"] = str(state)
        disabled = ["shell_tool", "unified_exec", "apply_patch_freeform", "apps", "plugins", "multi_agent", "collab", "browser_use", "computer_use", "image_generation", "memory_tool", "code_mode", "js_repl", "view_image", "hooks", "codex_hooks", "plugin_hooks", "memories"]
        command = [self.executable, "app-server", "--stdio", "-c", 'forced_login_method="chatgpt"']
        for flag in disabled:
            command += ["-c", f"features.{flag}=false"]
        command += ["-c", "features.skip_host_skill_discovery=true", "-c", 'web_search="disabled"']
        self.process = await asyncio.create_subprocess_exec(*command, env=environment, cwd=state,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=4*1024*1024)
        self.reader = asyncio.create_task(self._read())
        await self.request("initialize", {"clientInfo": {"name": "personal_assistant", "version": "0.1.0"}, "capabilities": {"experimentalApi": True}})
        await self._write({"method": "initialized"})
        account = await self.request("account/read", {"refreshToken": False})
        if (account.get("account") or {}).get("type") != "chatgpt":
            raise RuntimeError("Sign in to Codex with your ChatGPT subscription first. API billing is disabled.")
        params = {"baseInstructions": system_prompt, "cwd": str(state), "approvalPolicy": "never", "sandbox": "read-only",
                  "config": {"web_search": "disabled"}, "modelProvider": "openai"}
        if self.model:
            params["model"] = self.model
        if resume:
            params["threadId"] = resume
            try:
                result = await self.request("thread/resume", params)
                self.resumed = True
            except CodexRequestError as error:
                if not any(phrase in str(error).lower() for phrase in ("not found", "no rollout", "does not exist", "unable to find")):
                    raise
                params.pop("threadId")
        if not self.resumed:
            params["dynamicTools"] = [{"type": "function", "name": s.name, "description": s.description, "inputSchema": s.schema} for s in tools]
            params["environments"] = []
            result = await self.request("thread/start", params)
        self.session_id = result["thread"]["id"]

    async def send(self, text):
        result = await self.request("turn/start", {"threadId": self.session_id, "input": [{"type": "text", "text": text}], "environments": [], "effort": self.effort})
        self.turn_id = result["turn"]["id"]
        started = asyncio.get_running_loop().time()
        while True:
            try:
                message = await asyncio.wait_for(self.events.get(), 90)
            except asyncio.TimeoutError:
                try:
                    await self.interrupt()
                except Exception:
                    await self.close()
                raise RuntimeError("The reply timed out. Reconnect to continue.") from None
            if isinstance(message, Exception):
                raise message
            if asyncio.get_running_loop().time() - started > 300:
                await self.interrupt()
                raise TimeoutError("The reply took too long. Please try again.")
            method, params = message.get("method"), message.get("params", {})
            if "id" in message:
                if method == "item/tool/call" and params.get("threadId") == self.session_id:
                    name = params["tool"]
                    spec = self.tools.get(name)
                    yield Event("tool_use", name=name, payload=params.get("arguments", {}))
                    answer, failed = await run(spec, params["arguments"]) if spec else ("Unknown tool", True)
                    await self._write({"id": message["id"], "result": {"contentItems": [{"type": "inputText", "text": answer}], "success": not failed}})
                    yield Event("tool_result", name=name, payload={"content": answer, "is_error": failed})
                else:
                    await self._write({"id": message["id"], "error": {"code": -32601, "message": "Unsupported request"}})
                continue
            if params.get("threadId") != self.session_id:
                continue
            if params.get("turnId") and params["turnId"] != self.turn_id:
                continue
            if method == "thread/tokenUsage/updated":
                usage = params["tokenUsage"]["total"]
                if self.usage_baseline is None:
                    last = params["tokenUsage"]["last"]
                    self.usage_baseline = {k: usage.get(k, 0) - last.get(k, 0) for k in usage}
                self.latest_usage = usage
                for field, key in (("input_tokens", "inputTokens"), ("output_tokens", "outputTokens"), ("cache_read_tokens", "cachedInputTokens"), ("cache_write_tokens", "cacheWriteInputTokens")):
                    setattr(self.metrics, field, max(0, usage.get(key, 0) - self.usage_baseline.get(key, 0)))
            elif method == "item/agentMessage/delta":
                yield Event("text", text=params["delta"])
            elif method == "item/completed" and params.get("item", {}).get("type") == "agentMessage":
                yield Event("assistant_text", text=params["item"]["text"])
            elif method == "turn/completed" and params["turn"]["id"] == self.turn_id:
                self.turn_id = None
                if params["turn"].get("status") != "completed":
                    raise RuntimeError("The reply was interrupted or failed. You can continue the conversation.")
                self.metrics.turns += 1
                yield Event("done", payload=Metrics(turns=1).as_dict())
                return

    async def interrupt(self):
        if self.turn_id:
            await self.request("turn/interrupt", {"threadId": self.session_id, "turnId": self.turn_id})

    async def close(self):
        if self.process and self.process.returncode is None:
            self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()
        if self.reader:
            await asyncio.gather(self.reader, return_exceptions=True)
        return self.metrics
