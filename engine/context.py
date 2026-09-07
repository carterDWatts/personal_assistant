"""The deterministic snapshot of the map that opens a runtime session.

It is built from the views, never from the model's memory, and it is the same
on every device. The richer preload and the per-turn delta belong to the hooks.
"""

from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
from engine import config


def snapshot(map_, today=None, now=None):
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
    return "\n\n".join(parts)


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
        "select id, subject_name, relation, object_name, properties from memory.current_relationships order by subject_name, relation limit 100")
    if not rows:
        return "None yet."
    return "\n".join(
        f"  {r['subject_name']} {r['relation']} {r['object_name']}" + (f" {r['properties']}" if r["properties"] else "") + f" (relationship {r['id']})"
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
        "select id, kind, text, score, times_asked from memory.questions"
        " where closed_at is null and (deferred_until is null or deferred_until <= %s)"
        " order by score * power(0.7, times_asked) desc, id limit %s", (today, limit))
    if not rows:
        return "None."
    return "\n".join(f"  {r['text']} ({r['kind']}, question {r['id']})" for r in rows)


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
