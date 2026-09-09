"""Notion operations exposed to the assistant."""
from urllib.parse import quote

from engine.integrations.accounts import _request
from engine.integrations.results import snapshot as _result, tool


def _notion_search(args):
    body = {"query": args.get("query", ""), "page_size": 20, "sort": {"direction": "descending", "timestamp": "last_edited_time"}}
    if args.get("cursor"): body["start_cursor"] = args["cursor"]
    data = _request("notion", "search", body=body)
    items = []
    for item in data.get("results", []):
        title = item.get("title", [])
        for prop in item.get("properties", {}).values():
            if prop.get("type") == "title": title = prop.get("title", [])
        items.append({"id": item["id"], "type": item.get("object"), "title": "".join(t.get("plain_text", "") for t in title),
                      "url": item.get("url"), "last_edited_time": item.get("last_edited_time")})
    return _result(items=items, next_cursor=data.get("next_cursor"), has_more=data.get("has_more", False),
                   search_note="Title search, not full-text search. Only pages shared with this connection are visible.")


def _notion_read(args):
    params = {"page_size": 50}
    if args.get("cursor"): params["start_cursor"] = args["cursor"]
    data = _request("notion", "blocks/" + quote(args["block_id"], safe="") + "/children", params=params)
    blocks = []
    for block in data.get("results", []):
        kind = block.get("type", "unknown")
        content = block.get(kind, {})
        text = "".join(t.get("plain_text", "") for t in content.get("rich_text", []))
        cells = ["".join(t.get("plain_text", "") for t in cell) for cell in content.get("cells", [])]
        blocks.append({"id": block["id"], "type": kind, "text": text[:8000], "truncated": len(text) > 8000,
                       "cells": cells, "title": content.get("title"), "checked": content.get("checked"),
                       "has_children": block.get("has_children", False), "last_edited_time": block.get("last_edited_time")})
    return _result(blocks=blocks, next_cursor=data.get("next_cursor"), has_more=data.get("has_more", False),
                   content_note="Read blocks with has_children separately. Unsupported media is identified by type, not transcribed.")


def specs():
    cursor = {"type": "string", "maxLength": 2048}
    return [
        tool("notion_search", "Find Notion pages by title; only explicitly shared pages are visible. Follow next_cursor. Read page blocks before relying on content.", _notion_search, {"query": {"type": "string", "maxLength": 300}, "cursor": cursor}),
        tool("notion_read", "Read a Notion page's blocks. Follow next_cursor and call again for relevant has_children blocks; one page of results is not necessarily the whole document.", _notion_read, {"block_id": {"type": "string", "pattern": "^[a-fA-F0-9-]{32,36}$"}, "cursor": cursor}, ["block_id"])
    ]
