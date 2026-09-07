"""One conversation, across every device.

The canonical conversation is the message stream in the map. A runtime session
on a device is a cache of it. When the cache is current, the runtime resumes.
When another device has spoken since, a new runtime session is seeded with the
shared tail and carries on, so there is never a visible seam.
"""

from engine import config


class Conversation:
    def __init__(self, map_, device, runtime_name):
        self.map = map_
        self.device = device
        self.runtime_name = runtime_name

    def resolve(self, mode):
        """Decide how this process joins the conversation.

        Returns (segment_id, resume_session_id, seed_text). A morning always starts a fresh
        runtime session. Otherwise the latest session on this device resumes unless something
        was said elsewhere since, in which case a fresh session is seeded with the tail."""
        latest = self.latest_segment()
        if mode != "morning" and latest and not self.spoken_elsewhere_since(latest["id"]):
            return latest["id"], latest["runtime_session_id"], None
        seed = self.seed_text(self.tail(config.SEED_MESSAGES))
        return self.open_segment(mode), None, seed

    def latest_segment(self):
        return self.map.row(
            "select id, runtime_session_id from memory.conversations"
            " where device = %s and runtime = %s and runtime_session_id is not null order by started_at desc limit 1",
            (self.device, self.runtime_name))

    def spoken_elsewhere_since(self, segment_id):
        last = self.map.value("select coalesce(max(id), 0) from memory.messages where conversation_id = %s", (segment_id,))
        return bool(self.map.value(
            "select exists (select 1 from memory.messages where id > %s and conversation_id <> %s and role in ('user', 'assistant'))",
            (last, segment_id)))

    def open_segment(self, mode):
        return self.map.value(
            "insert into memory.conversations (agent, device, runtime) values (%s, %s, %s) returning id",
            (mode, self.device, self.runtime_name))

    def record(self, segment_id, role, content, payload=None):
        from engine.db import jsonb
        return self.map.value(
            "insert into memory.messages (conversation_id, seq, role, content, payload)"
            " values (%s, (select coalesce(max(seq), 0) + 1 from memory.messages where conversation_id = %s), %s, %s, %s) returning id",
            (segment_id, segment_id, role, content, jsonb(payload) if payload is not None else None))

    def set_runtime_session(self, segment_id, session_id):
        self.map.execute("update memory.conversations set runtime_session_id = %s where id = %s", (session_id, segment_id))

    def close_segment(self, segment_id, ended_by, metrics=None, summary=None):
        from engine.db import jsonb
        self.map.execute(
            "update memory.conversations set ended_at = now(), ended_by = %s, metrics = %s, summary = coalesce(%s, summary) where id = %s",
            (ended_by, jsonb(metrics or {}), summary, segment_id))

    def tail(self, n):
        rows = self.map.rows(
            "select m.role, m.content, m.created_at, c.device from memory.messages m"
            " join memory.conversations c on c.id = m.conversation_id"
            " where m.role in ('user', 'assistant') and m.content is not null order by m.id desc limit %s", (n,))
        return list(reversed(rows))

    def seed_text(self, messages):
        if not messages:
            return None
        lines = ["Earlier in this conversation, most recent last:"]
        for m in messages:
            when = m["created_at"].strftime("%b %d %H:%M")
            where = f" on {m['device']}" if m["device"] and m["device"] != self.device else ""
            lines.append(f"[{when}{where}] {m['role']}: {m['content']}")
        return "\n".join(lines)
