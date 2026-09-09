"""Todoist operations exposed to the assistant."""

from engine.integrations.accounts import _request
from engine.integrations.results import snapshot as _result, tool


def _todoist(args):
    params = {"limit": 50}
    for key in ("cursor", "project_id"):
        if args.get(key): params[key] = args[key]
    data = _request("todoist", "tasks", params=params)
    return _result(tasks=[{k: item[k] for k in ("id", "content", "description", "project_id", "labels",
                     "priority", "due", "deadline", "duration", "url", "is_completed") if k in item}
                     for item in data.get("results", [])], next_cursor=data.get("next_cursor"))


def specs():
    string = {"type": "string", "minLength": 1, "maxLength": 500}
    cursor = {"type": "string", "maxLength": 2048}
    return [
        tool("todoist_tasks", "Read active Todoist tasks before planning work. Follow next_cursor. Read only; cannot create or complete tasks.", _todoist, {"project_id": string, "cursor": cursor})
    ]
