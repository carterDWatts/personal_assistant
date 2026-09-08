"""Discover selectable models from the subscription harness on this host."""
import os
from engine.runtime.codex import CodexRuntime

async def available():
    result = []
    runtime = CodexRuntime()
    try:
        await runtime.open('Discover available models. No conversation.', [])
        page = await runtime.request('model/list', {'limit': 100})
        for model in page.get('data', []):
            if not model.get('hidden'):
                result.append({'id': 'codex/' + model['model'], 'runtime': 'codex',
                               'model': model['model'], 'name': model.get('displayName', model['model'])})
    except Exception:
        pass
    finally:
        await runtime.close()
    if os.environ.get('CLAUDE_CODE_OAUTH_TOKEN'):
        for model in ('fable', 'sonnet', 'opus', 'haiku'):
            result.append({'id': 'claude-agent-sdk/' + model, 'runtime': 'claude-agent-sdk',
                           'model': model, 'name': 'Claude ' + model.title()})
    return result
