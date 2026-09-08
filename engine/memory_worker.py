"""Drain durable memory work independently of the conversational runtime."""
import asyncio
import copy
import os
import re
import subprocess
import sys

from jsonschema import validate
from engine import config, context
from engine.db import Map, dumps, jsonb
from engine.runtime import load
from engine.tools import Tools, ToolSpec, READ_TOOLS

LOCK = 'personal-assistant-memory-worker'


def kick(runtime):
    """Start a detached drainer; a database lock permits just one model worker."""
    if runtime not in ('codex', 'claude-agent-sdk'):
        return
    try:
        subprocess.Popen([sys.executable, '-m', 'engine.memory_worker'], cwd=config.ROOT,
                         env=os.environ.copy(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass  # The durable job is picked up on the next turn or app launch.


def resolve_refs(value, ids):
    if isinstance(value, dict):
        if set(value) == {'$ref'}:
            if value['$ref'] not in ids:
                raise ValueError('Unknown operation reference')
            return ids[value['$ref']]
        return {k: resolve_refs(v, ids) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve_refs(v, ids) for v in value]
    return value


class Worker:
    def __init__(self, map_, factory=None):
        self.map = map_
        self.factory = factory or self.runtime

    @staticmethod
    def runtime(name):
        if name == 'codex':
            return load(name)(model=os.environ.get('ASSISTANT_MEMORY_OPENAI_MODEL', 'gpt-5.4-mini'), effort='low')
        if name == 'claude-agent-sdk':
            return load(name)(model=os.environ.get('ASSISTANT_MEMORY_CLAUDE_MODEL', 'haiku'), effort='low')
        raise RuntimeError('Unsupported memory runtime')

    def oldest(self):
        return self.map.row(
            "select j.*, m.content, m.created_at, m.conversation_id, c.runtime from memory.memory_jobs j"
            " join memory.messages m on m.id=j.message_id join memory.conversations c on c.id=m.conversation_id"
            " where j.status <> 'done' order by j.message_id limit 1")

    async def save(self, job, specs, args):
        # No network calls inside this transaction. Retrying a completed job is a no-op.
        with self.map.conn.transaction():
            status = self.map.value('select status from memory.memory_jobs where message_id=%s for update', (job['message_id'],))
            if status == 'done':
                return {'saved': True, 'already_done': True}
            ids = {}
            for operation in args['operations']:
                spec = specs[operation['tool']]
                resolved = resolve_refs(operation['arguments'], ids)
                validate(resolved, spec.schema)
                result = await spec.fn(resolved)
                if operation.get('as'):
                    label = operation['as']
                    if label in ids or not isinstance(result, dict) or 'id' not in result:
                        raise ValueError('Each reference needs a unique label and a returned id')
                    ids[label] = str(result['id'])
            self.map.execute("update memory.memory_jobs set status='done', completed_at=now(), last_error=null where message_id=%s", (job['message_id'],))
        return {'saved': True, 'operations': len(args['operations'])}

    async def process(self, job):
        runtime = None
        try:
            self.map.execute("update memory.memory_jobs set status='processing', attempts=attempts+1 where message_id=%s", (job['message_id'],))
            # Only skip an opening greeting; after a question it could be an answer.
            if re.fullmatch(r'\s*(hi|hello|hey|thanks|thank you)[!.\s]*', job['content'], re.I) and not self.map.value("select exists(select 1 from memory.messages where id<%s and role='assistant')", (job['message_id'],)):
                await self.save(job, {}, {'operations': []})
                return
            tools = Tools(self.map, 'memory-worker')
            tools.message_id = job['message_id']
            tools.observed_at = job['created_at']
            all_specs = tools.specs()
            writes = {s.name: s for s in all_specs if s.name not in READ_TOOLS}
            entity = writes['entity_upsert']
            schema = copy.deepcopy(entity.schema)
            schema['properties'].pop('description', None)
            writes['entity_upsert'] = ToolSpec(entity.name, 'Create or resolve canonical identity only. Store properties with fact_assert.', schema, entity.fn)
            async def save(args):
                return await self.save(job, writes, args)
            batch = ToolSpec('save_memory', 'Commit the complete set of memory updates for this message atomically.', {
                'type':'object','properties':{'operations':{'type':'array','maxItems':60,'items':{
                    'type':'object','properties':{'tool':{'type':'string','enum':sorted(writes)},
                    'arguments':{'type':'object'},'as':{'type':'string'}},'required':['tool','arguments'],'additionalProperties':False}}},
                'required':['operations'],'additionalProperties':False}, save)
            # The batch carries the exact existing tool schemas so it can construct valid operations in one pass.
            schemas = [{'name':s.name,'description':s.description,'arguments':s.schema} for s in writes.values()]
            system = config.prompt('memory') + '\nAvailable operations:\n' + dumps(schemas)
            nearby = self.map.rows("select role,content,created_at from memory.messages where id<=%s and role in ('user','assistant') order by id desc limit 12", (job['message_id'],))
            reply = self.map.row("select content from memory.messages where conversation_id=%s and id>%s and role='assistant'"
                                 " and id < coalesce((select min(id) from memory.messages where conversation_id=%s and id>%s and role='user'),9223372036854775807) order by id limit 1",
                                 (job['conversation_id'],job['message_id'],job['conversation_id'],job['message_id']))
            registries = {'attributes':self.map.rows('select name,value_type,cardinality from memory.attributes'),
                          'relations':self.map.rows('select name,cardinality from memory.relations')}
            text = context.snapshot(self.map, include_pending=False) + '\nRegistries:\n' + dumps(registries)
            text += '\nNearby conversation:\n' + dumps(list(reversed(nearby)))
            text += '\nSelected message:\n' + dumps({'id':job['message_id'],'time':job['created_at'],'content':job['content'],'assistant_reply':reply})
            runtime = self.factory(job['runtime'])
            await runtime.open(system, [s for s in all_specs if s.name in READ_TOOLS] + [batch])
            async def consume():
                async for _ in runtime.send(text):
                    pass
            await asyncio.wait_for(consume(), 180)
            if self.map.value('select status from memory.memory_jobs where message_id=%s', (job['message_id'],)) != 'done':
                raise RuntimeError('Memory worker did not commit an update')
        except asyncio.CancelledError:
            self.map.execute("update memory.memory_jobs set status='pending', last_error=null where message_id=%s and status <> 'done'", (job['message_id'],))
            raise
        except Exception as error:
            # Keep the oldest failed job in front; newer facts must not be applied before it.
            message = str(error)[:300] if isinstance(error, RuntimeError) else type(error).__name__
            self.map.execute("update memory.memory_jobs set status='error', last_error=%s, available_at=now()+interval '5 minutes' where message_id=%s and status <> 'done'", (message,job['message_id']))
        finally:
            if runtime:
                metrics = await runtime.close()
                self.map.execute('update memory.memory_jobs set metrics=%s where message_id=%s', (jsonb(metrics.as_dict()),job['message_id']))

    async def drain(self, on_processed=None, can_process=lambda: True):
        while not self.map.value('select pg_try_advisory_lock(hashtextextended(%s,0))', (LOCK,)):
            if not self.oldest():
                return
            await asyncio.sleep(0.25)
        try:
            while can_process() and (job := self.oldest()):
                if not self.map.value('select %s <= now()', (job['available_at'],)):
                    return
                await self.process(job)
                if on_processed:
                    await on_processed()
        finally:
            self.map.execute('select pg_advisory_unlock(hashtextextended(%s,0))', (LOCK,))


async def main():
    # Finder-launched engines already load these, but the standalone worker can also resume on its own.
    from engine.desktop import load_settings
    load_settings()
    # config is imported above; connection URL is chosen explicitly after loading the profile.
    url = os.environ.get('ASSISTANT_TEST_DATABASE_URL') or 'postgresql://postgres:test@localhost:55433/app' if config.ENV == 'test' else os.environ.get('ASSISTANT_DATABASE_URL')
    map_ = Map(url)
    try:
        await Worker(map_).drain()
    finally:
        map_.close()


if __name__ == '__main__':
    asyncio.run(main())
