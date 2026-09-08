import asyncio
import unittest
from engine.runtime.codex import CodexRuntime
from engine.tools import ToolSpec


class codex_test(unittest.IsolatedAsyncioTestCase):
    async def test_streaming_tool_round_trip(self):
        runtime = CodexRuntime(model="selected-model")
        runtime.session_id = 'thread'
        written = []
        async def request(method, params):
            self.assertEqual(params.get('model'), 'selected-model')
            return {'turn': {'id':'turn'}}
        async def write(message): written.append(message)
        async def tool(args): return {'answer': args['value']}
        runtime.request, runtime._write = request, write
        runtime.tools = {'lookup': ToolSpec('lookup','Lookup',{'type':'object','properties':{'value':{'type':'integer'}},'required':['value']},tool)}
        events = [
            {'id':20,'method':'item/tool/call','params':{'threadId':'thread','tool':'lookup','arguments':{'value':7}}},
            {'method':'item/agentMessage/delta','params':{'threadId':'thread','delta':'Seven.'}},
            {'method':'item/completed','params':{'threadId':'thread','item':{'type':'agentMessage','text':'Seven.'}}},
            {'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'completed'}}},
        ]
        for event in events: await runtime.events.put(event)
        received = [event async for event in runtime.send('lookup')]
        self.assertEqual([e.kind for e in received],['tool_use','tool_result','text','assistant_text','done'])
        self.assertTrue(written[0]['result']['success'])
        self.assertEqual(written[0]['id'],20)

    async def test_bad_arguments_do_not_execute_tool(self):
        runtime = CodexRuntime(); runtime.session_id = 'thread'
        called=[];written=[]
        async def tool(args): called.append(args)
        async def request(method,params):return {'turn':{'id':'turn'}}
        async def write(message):written.append(message)
        runtime.request,runtime._write=request,write
        runtime.tools={'lookup':ToolSpec('lookup','Lookup',{'type':'object','required':['id'],'properties':{'id':{'type':'integer'}}},tool)}
        await runtime.events.put({'id':1,'method':'item/tool/call','params':{'threadId':'thread','tool':'lookup','arguments':{}}})
        await runtime.events.put({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'failed'}}})
        with self.assertRaises(RuntimeError):
            async for _ in runtime.send('test'):pass
        self.assertEqual(called,[])
        self.assertFalse(written[0]['result']['success'])

    async def test_disconnect_fails_pending_requests(self):
        runtime=CodexRuntime()
        class Process:
            stdout=asyncio.StreamReader()
        runtime.process=Process()
        future=asyncio.get_running_loop().create_future();runtime.pending[1]=future
        runtime.process.stdout.feed_eof()
        await runtime._read()
        with self.assertRaises(RuntimeError):await future
        self.assertIsInstance(await runtime.events.get(),RuntimeError)

    async def test_interrupt_during_turn_start_is_not_lost(self):
        runtime = CodexRuntime(); runtime.session_id = 'thread'
        requested = []
        async def request(method, params):
            requested.append(method)
            if method == 'turn/start':
                await runtime.interrupt()
                return {'turn': {'id': 'turn'}}
            return {}
        runtime.request = request
        await runtime.events.put({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'interrupted'}}})
        with self.assertRaises(RuntimeError):
            async for _ in runtime.send('test'): pass
        self.assertEqual(requested, ['turn/start', 'turn/interrupt'])
        self.assertFalse(runtime.interrupt_requested)
