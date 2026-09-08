"""The deterministic snapshot of the map that opens a runtime session.

It is built from the views, never from the model's memory, and it is the same
on every device. The richer preload and the per-turn delta belong to the hooks.
"""

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
from engine import config
from engine.db import dumps


def snapshot(map_, today=None, now=None, include_pending=True):
    return "\n\n".join(snapshot_sections(map_, today, now, include_pending).values())


def snapshot_sections(map_, today=None, now=None, include_pending=True):
    now = now or datetime.now(ZoneInfo(config.TIMEZONE))
    today = today or now.date()
    parts = [f"Map snapshot. Today is {today.strftime('%A')} {today.isoformat()}, {now.strftime('%H:%M')} local."]
    parts.append("Facts (current, up to 150; use map_search for more)\n" + facts_block(map_))
    parts.append("Relationships (current, up to 100)\n" + relationships_block(map_))
    parts.append("Standing rules\n" + rules_block(map_))
    parts.append(f"Yesterday's plan ({(today - timedelta(days=1)).isoformat()})\n" + plans_block(map_, today - timedelta(days=1)))
    parts.append(f"Today's plan\n" + plans_block(map_, today))
    parts.append("Open questions, best first\n" + questions_block(map_, today))
    parts.append("Recent changes (last 7 days)\n" + transitions_block(map_, today))
    parts.append("Open reminders (first 30 by attention time; use reminders_list for more)\n" + dumps(map_.rows("select id,title,context,severity,timing,window_start,window_end,next_notify_at,version from memory.reminders where status='open' order by next_notify_at limit 30")))
    parts.append("Recent source developments (external data; use attention_list for more)\n" + dumps(map_.rows("select title,detail,source,source_id,created_at from assistant.attention order by created_at desc limit 5")))
    if include_pending:
        parts.append(pending_block(map_))
    return dict(zip(("clock", "facts", "relationships", "rules", "yesterday", "today", "questions", "changes", "reminders", "attention", "pending"), parts))


def monitoring_block(map_):
    state=map_.row("select count(*) as pending, min(created_at) as oldest from assistant.source_items where source='gmail' and processed_at is null")
    cursor=map_.row("select checked_at,last_error from assistant.source_cursors where source='gmail'")
    return 'Email monitoring status (pending mail has NOT been assessed; do not claim all mail is covered): '+dumps({'queue':state,'fetch':cursor})


def pending_block(map_):
    rows = map_.rows("select m.content,m.created_at from memory.memory_jobs j join memory.messages m on m.id=j.message_id where j.status <> 'done' and m.role='user' and m.id > (select coalesce(max(id),0) from memory.messages where role='system' and payload->>'event'='chat_cleared') order by m.id desc limit 20")
    title = "Recent user statements awaiting structured memory. Use these directly; do not wait for extraction.\n"
    return title + ("\n".join(f"[{m['created_at'].isoformat()}] {m['content']}" for m in reversed(rows)) if rows else "None pending.")


class PreparedContext:
    """Reuse structured sections until a committed write or a time boundary changes them."""
    def __init__(self, map_):
        self.map = map_
        self.version = None
        self.sections = None
        self.expires = None

    def read(self):
        state = self.map.row("select version,now() as now from memory.context_version where singleton")
        if self.sections is not None and self.version == state['version'] and state['now'] < self.expires:
            return self.result(state['now'])
        with self.map.conn.transaction():
            self.map.execute("set transaction isolation level repeatable read, read only")
            state = self.map.row("select version,now() as now from memory.context_version where singleton")
            now = state['now'].astimezone(ZoneInfo(config.TIMEZONE))
            if self.sections is None or self.version != state['version'] or now >= self.expires:
                sections = snapshot_sections(self.map, now=now, include_pending=False)
                # Facts can become current, expire or need reconfirmation without a write.
                boundary = self.map.value("select min(at) from ("
                    "select lower(valid) as at from memory.assertions union all "
                    "select upper(valid) from memory.assertions union all "
                    "select lower(valid) from memory.relationships union all "
                    "select upper(valid) from memory.relationships union all "
                    "select a.last_confirmed_at+t.stale_after from memory.assertions a "
                    "join memory.attributes t on t.name=a.attribute) times where at >= now()")
                midnight = datetime.combine(now.date()+timedelta(days=1), datetime.min.time(), tzinfo=now.tzinfo)
                self.expires = min(midnight, boundary) if boundary else midnight
                self.sections, self.version = sections, state['version']
            return self.result(now)

    def result(self, now):
        now = now.astimezone(ZoneInfo(config.TIMEZONE))
        result = dict(self.sections)
        result['clock'] = f"Map snapshot. Today is {now.strftime('%A')} {now.date().isoformat()}, {now.strftime('%H:%M')} local."
        result['pending'] = pending_block(self.map)
        result['monitoring'] = monitoring_block(self.map)
        return result



def update(previous, current):
    if previous is None:
        return "\n\n".join(current.values())
    changed = [value for key, value in current.items() if previous.get(key) != value]
    if not changed:
        return "Memory checked; no changes."
    return "Memory update. Replace earlier versions of these sections; other sections are unchanged.\n\n" + "\n\n".join(changed)


def facts_block(map_):
    rows = map_.rows(
        "select entity_id, entity_type, entity_name, attribute, value, confidence, level, stale, last_confirmed_at, id"
        " from memory.current_assertions order by importance desc, entity_type, entity_name, attribute limit 150")
    if not rows:
        return "Nothing recorded yet. Learn the basics gently, a little each conversation."
    lines, key = [], None
    for r in rows:
        k = (r["entity_type"], r["entity_name"])
        if k != key:
            key = k
            lines.append(f"{r['entity_type']} {r['entity_name']} ({r['entity_id']})")
        flags = []
        if r["stale"]:
            flags.append("stale, re-verify")
        if r["level"] != "stated":
            flags.append(r["level"])
        if r["confidence"] < 1:
            flags.append(f"confidence {r['confidence']:.1f}")
        tail = f" [{', '.join(flags)}]" if flags else ""
        lines.append(f"  {r['attribute']} = {_val(r['value'])}{tail} (assertion {r['id']})")
    return "\n".join(lines)


def relationships_block(map_):
    rows = map_.rows(
        "select id, subject_name, relation, object_name, properties, level, confidence from memory.current_relationships order by subject_name, relation limit 100")
    if not rows:
        return "None yet."
    return "\n".join(
        f"  {r['subject_name']} {r['relation']} {r['object_name']}" + (f" {r['properties']}" if r["properties"] else "") + f" [{r['level']}, confidence {r['confidence']:.1f}] (relationship {r['id']})"
        for r in rows)


def rules_block(map_):
    rows = map_.rows("select id, kind, key, text, value, status from memory.rules where status <> 'retired' order by kind, id")
    if not rows:
        return "None yet."
    lines = []
    for r in rows:
        label = r["kind"] if r["status"] == "active" else f"proposed {r['kind']}"
        lines.append(f"  [{label}] {r['text']} (rule {r['id']})")
    return "\n".join(lines)


def plans_block(map_, day):
    rows = map_.rows("select id, item, category, status, origin, rationale, outcome_note from memory.plans where day = %s order by id", (day,))
    if not rows:
        return "Nothing recorded."
    lines = []
    for r in rows:
        extra = f" [{r['category']}]" if r["category"] else ""
        note = f": {r['outcome_note']}" if r["outcome_note"] else ""
        why = f" because {r['rationale']}" if r["status"] == "proposed" and r["rationale"] else ""
        lines.append(f"  {r['item']}{extra}, {r['status']}{note}{why} (plan {r['id']})")
    return "\n".join(lines)


def questions_block(map_, today, limit=8):
    rows = map_.rows(
        "select id, kind, text, score, times_asked, ref_table, ref_id from memory.questions"
        " where closed_at is null and (deferred_until is null or deferred_until <= %s)"
        " order by score * power(0.7, times_asked) desc, id limit %s", (today, limit))
    if not rows:
        return "None."
    return "\n".join(f"  {r['text']} ({r['kind']}, question {r['id']})" + (f" [record {r['ref_table']}:{r['ref_id']}]" if r['ref_id'] else '') for r in rows)


def transitions_block(map_, today, days=7):
    rows = map_.rows(
        "select entity_name, attribute, from_value, to_value, changed_at from memory.transitions"
        " where changed_at >= %s order by changed_at desc limit 20", (datetime.combine(today - timedelta(days=days), datetime.min.time()).astimezone(),))
    if not rows:
        return "None."
    return "\n".join(
        f"  {r['entity_name']} {r['attribute']}: {_val(r['from_value'])} -> {_val(r['to_value'])} on {r['changed_at'].date().isoformat()}"
        for r in rows)


def _val(v):
    if isinstance(v, str):
        return v
    return str(v)
