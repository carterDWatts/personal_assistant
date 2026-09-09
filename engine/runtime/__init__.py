"""What the engine needs from whatever runs the model.

A runtime opens a session with a system prompt and our tools, takes a message,
streams back events, and reports what the session cost. Swapping the model
vendor means writing one more module in this package and nothing else.
"""

from dataclasses import dataclass
from typing import AsyncIterator, Protocol

from engine.tools import ToolSpec


@dataclass
class Event:
    kind: str                    # text | assistant_text | tool_use | tool_result | done
    text: str = ""
    name: str = ""
    payload: dict | None = None


@dataclass
class Metrics:
    cost_usd: float = 0.0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    turns: int = 0

    def add(self, other):
        self.cost_usd += other.cost_usd
        self.input_tokens += other.input_tokens
        self.output_tokens += other.output_tokens
        self.cache_read_tokens += other.cache_read_tokens
        self.cache_write_tokens += other.cache_write_tokens
        self.turns += other.turns

    def as_dict(self):
        return {"cost_usd": round(self.cost_usd, 4), "input_tokens": self.input_tokens, "output_tokens": self.output_tokens,
                "cache_read_tokens": self.cache_read_tokens, "cache_write_tokens": self.cache_write_tokens, "turns": self.turns}


class Runtime(Protocol):
    name: str
    session_id: str | None

    async def open(self, system_prompt: str, tools: list[ToolSpec], resume: str | None = None) -> None: ...

    def send(self, text: str, images: list[dict] | None = None) -> AsyncIterator[Event]: ...

    async def interrupt(self) -> None: ...

    async def close(self) -> Metrics: ...


def load(name):
    if name == "codex":
        from engine.runtime.codex import CodexRuntime
        return CodexRuntime
    if name == "claude-agent-sdk":
        from engine.runtime.claude_agent_sdk import ClaudeAgentSDKRuntime
        return ClaudeAgentSDKRuntime
    raise ValueError(f"unknown runtime {name}")
