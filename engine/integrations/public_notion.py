"""Published Notion pages, using the same anonymous read endpoint as the website.

This endpoint is not part of Notion's versioned API. Fail explicitly if its
response changes; never substitute account access for a failed public read.
"""
import json
import re
from urllib.parse import urlsplit
from uuid import UUID


def page_id(url):
    parts = urlsplit(url)
    host = parts.hostname or ''
    if parts.scheme != 'https' or not (host == 'notion.site' or host.endswith('.notion.site')):
        return None
    if parts.username or parts.password or parts.port not in (None, 443):
        return None
    match = re.search(r'([a-fA-F0-9]{32}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})$', parts.path.rstrip('/'))
    return str(UUID(match[1])) if match else None


def read_page(url):
    from engine.integrations.web import open_public, MAX_BYTES
    root = page_id(url)
    host = urlsplit(url).hostname
    endpoint = f'https://{host}/api/v3/loadPageChunk'
    blocks, cursor, downloaded = {}, {'stack': []}, 0
    for chunk in range(5):
        # POST is the site's read protocol. No generic method or endpoint is
        # exposed to the agent, and no session credentials are sent.
        body = dict(pageId=root, limit=100, cursor=cursor, chunkNumber=chunk, verticalColumns=False)
        with open_public(endpoint, https_only=True, json_body=body) as (_, response):
            if response.status != 200:
                return {'url': url, 'status': response.status, 'error': 'Notion could not provide this public page.'}
            data = response.read(MAX_BYTES - downloaded + 1)
        downloaded += len(data)
        if downloaded > MAX_BYTES: raise ValueError('The page exceeds the download limit.')
        result = json.loads(data)
        for id, entry in result.get('recordMap', {}).get('block', {}).items():
            value = entry.get('value', {})
            blocks[id] = value.get('value', value)
        cursor = result.get('cursor', {})
        if not cursor.get('stack'): break
    if root not in blocks or blocks[root].get('alive') is False:
        return {'url': url, 'error': 'Notion returned no public page content. The page may be unavailable or its public reader may have changed.'}
    lines, links, visited = [], [], set()
    incomplete = bool(cursor.get('stack'))

    def rich_text(value):
        words = []
        for segment in value or []:
            if not isinstance(segment, list) or not segment or not isinstance(segment[0], str): continue
            words.append(segment[0])
            for annotation in segment[1] if len(segment) > 1 else []:
                if len(annotation) > 1 and annotation[0] == 'a':
                    link(annotation[1], segment[0])
        return ''.join(words)

    def link(target, text):
        if isinstance(target, str) and urlsplit(target).scheme in ('http', 'https') and len(links) < 40:
            item = {'url': target, 'text': text[:200]}
            if item not in links: links.append(item)

    def visit(id):
        nonlocal incomplete
        if id in visited: return
        visited.add(id)
        block = blocks.get(id, {})
        if not block: incomplete = True; return
        if block.get('alive') is False: return
        title = rich_text(block.get('properties', {}).get('title'))
        if title: lines.append(title)
        if id != root and block.get('type') == 'page':
            link(f'https://{host}/{id.replace("-", "")}', title)
            return
        if block.get('type') in ('collection_view', 'collection_view_page'):
            incomplete = True  # A database view is not the same as its loaded rows.
        for child in block.get('content', []): visit(child)

    visit(root)
    title = rich_text(blocks[root].get('properties', {}).get('title'))
    if not lines: return {'url': url, 'error': 'Notion returned no readable public page text.'}
    return {'title': title, 'text': '\n\n'.join(lines), 'links': links, 'incomplete': incomplete}
