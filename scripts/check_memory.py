"""Live subscription check: retrieve a fact that has never appeared in chat.

Run from the repository: python3 -m scripts.check_memory
Temporary records are rolled back, including on failure. No chat is changed.
"""
import asyncio
import os
import secrets
from urllib.parse import urlsplit

from engine import config
from engine.db import Map
from engine.runtime import load
from engine.tools import Tools, ToolSpec


async def main():
    url = os.environ.get('ASSISTANT_TEST_DATABASE_URL') or 'postgresql://postgres:test@localhost:55433/app'
    target = urlsplit(url)
    if target.hostname not in ('localhost', '127.0.0.1', '::1') or target.port not in (55432, 55433):
        raise RuntimeError('This check requires the local test database')
    config.ENV = 'test'
    map_ = Map(url)
    runtime = load('codex')(model='gpt-5.4-mini', effort='low')
    name = 'Memory probe ' + secrets.token_hex(5)
    expected = secrets.token_hex(8)
    calls = []
    try:
        with map_.conn.transaction(force_rollback=True):
            tools = Tools(map_, 'memory-check')
            entity = await tools.entity_upsert({'type':'topic', 'name':name})
            attribute = 'probe_' + secrets.token_hex(5)
            await tools.attribute_register({'name':attribute, 'value_type':'text', 'cardinality':'single'})
            await tools.fact_assert({'entity_id':str(entity['id']), 'attribute':attribute, 'value':expected, 'valid_from':'2020-01-01T00:00:00Z'})
            specs = []
            for spec in tools.read_specs():
                if spec.name not in ('map_search', 'entity_view'):
                    continue
                async def tracked(args, spec=spec):
                    calls.append(spec.name)
                    return await spec.fn(args)
                specs.append(ToolSpec(spec.name, spec.description, spec.schema, tracked))
            await runtime.open(config.prompt('persona'), specs)
            reply = ''
            async def consume():
                nonlocal reply
                async for event in runtime.send(f'What is the stored {attribute} value for {name}?'):
                    if event.kind == 'assistant_text':
                        reply += event.text
            await asyncio.wait_for(consume(), 90)
            if expected not in reply or not calls:
                raise AssertionError(f'The fresh session did not retrieve the stored value. Tools: {calls}; reply: {reply}')
            print('PASS: fresh session retrieved a random fact through ' + ', '.join(calls))
            print('No transcript, snapshot, or expected answer was supplied to the model.')
    finally:
        await runtime.close()
        map_.close()
    print('Temporary memory rolled back. Existing chats and facts are unchanged.')


if __name__ == '__main__':
    asyncio.run(main())
