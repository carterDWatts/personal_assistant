"""Claude adapter using the existing local login, with no API-key fallback."""

import os
from pathlib import Path
from claude_agent_sdk import (
    AssistantMessage, ClaudeAgentOptions, ClaudeSDKClient, ResultMessage, StreamEvent, TextBlock, ToolResultBlock,
    ToolUseBlock, UserMessage, create_sdk_mcp_server, tool,
)

from engine import config, tools as tools_mod
from engine.runtime import Event, Metrics

SERVER = "map"


class ClaudeAgentSDKRuntime:
    name = "claude-agent-sdk"

    def __init__(self, model=None, effort=None, budget_usd=None, cwd=None):
        self.model = model or config.MODEL
        self.effort = effort or config.EFFORT
        self.budget_usd = config.SESSION_BUDGET_USD if budget_usd is None else budget_usd
        state = Path.home() / "Library/Application Support/Personal Assistant" / config.ENV / "claude"
        state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.cwd = str(cwd or state)
        self.session_id = None
        self.client = None
        self.metrics = Metrics()

    async def open(self, system_prompt, tools, resume=None):
        if any(os.environ.get(k) for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")):
            raise RuntimeError("Remove API billing credentials before using the subscription runtime.")
        server = create_sdk_mcp_server(name=SERVER, tools=[_wrap(spec) for spec in tools])
        options = ClaudeAgentOptions(
            system_prompt=system_prompt,
            model=self.model,
            effort=self.effort,
            tools=[],                                   # no built-in tools; the map is the only surface
            mcp_servers={SERVER: server},
            strict_mcp_config=True,                     # nothing from ~/.claude rides along
            allowed_tools=[f"mcp__{SERVER}__{spec.name}" for spec in tools],
            setting_sources=[],
            include_partial_messages=True,
            max_buffer_size=24*1024*1024,
            max_budget_usd=self.budget_usd,
            resume=resume,
            cwd=self.cwd,
        )
        self.client = ClaudeSDKClient(options=options)
        await self.client.connect()

    async def send(self, text, images=None):
        if images:
            async def message():
                yield {"type":"user","message":{"role":"user","content":[{"type":"text","text":text}]+[
                    {"type":"image","source":{"type":"base64","media_type":image['mime'],"data":image['data']}} for image in images]},"parent_tool_use_id":None}
            await self.client.query(message())
        else:
            await self.client.query(text)
        async for m in self.client.receive_response():
            if isinstance(m, StreamEvent):
                ev = m.event or {}
                if ev.get("type") == "content_block_delta" and ev.get("delta", {}).get("type") == "text_delta":
                    yield Event("text", text=ev["delta"]["text"])
            elif isinstance(m, AssistantMessage):
                for block in m.content:
                    if isinstance(block, ToolUseBlock):
                        yield Event("tool_use", name=block.name.replace(f"mcp__{SERVER}__", ""), payload=dict(block.input or {}))
                    elif isinstance(block, TextBlock) and block.text:
                        yield Event("assistant_text", text=block.text)
            elif isinstance(m, UserMessage) and isinstance(m.content, list):
                for block in m.content:
                    if isinstance(block, ToolResultBlock):
                        yield Event("tool_result", name=block.tool_use_id,
                                    payload={"content": _plain(block.content), "is_error": bool(block.is_error)})
            elif isinstance(m, ResultMessage):
                self.session_id = m.session_id
                if m.is_error or m.subtype != "success":
                    raise RuntimeError((m.result or "Claude stopped: " + m.subtype)[:600])
                turn = _metrics(m)
                self.metrics.add(turn)
                yield Event("done", payload=turn.as_dict())

    async def interrupt(self):
        if self.client is not None:
            await self.client.interrupt()

    async def close(self):
        if self.client is not None:
            await self.client.disconnect()
            self.client = None
        return self.metrics


def _wrap(spec):
    @tool(spec.name, spec.description, spec.schema)
    async def handler(args):
        text, is_error = await tools_mod.run(spec, args)
        from engine.images import tool_content
        text, images = tool_content(text)
        out = {"content": [{"type": "text", "text": text}]+[{"type":"image","mimeType":image['mime'],"data":image['data']} for image in images]}
        if is_error:
            out["is_error"] = True
        return out
    return handler


def _plain(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return str(content) if content is not None else ""


def _metrics(m):
    usage = m.usage or {}
    return Metrics(
        cost_usd=float(m.total_cost_usd or 0.0),
        input_tokens=int(usage.get("input_tokens") or 0),
        output_tokens=int(usage.get("output_tokens") or 0),
        cache_read_tokens=int(usage.get("cache_read_input_tokens") or 0),
        cache_write_tokens=int(usage.get("cache_creation_input_tokens") or 0),
        turns=int(getattr(m, "num_turns", 0) or 1),
    )
