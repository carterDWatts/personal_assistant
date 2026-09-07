import unittest
from unittest.mock import patch
from claude_agent_sdk import ResultMessage
from engine.runtime.claude_agent_sdk import ClaudeAgentSDKRuntime


class claude_test(unittest.IsolatedAsyncioTestCase):
    async def test_subscription_limit_is_an_error_even_with_success_subtype(self):
        result = ResultMessage(subtype='success', duration_ms=1, duration_api_ms=1, is_error=True,
            num_turns=1, session_id='test', total_cost_usd=0, usage={}, result="You've hit your session limit")
        class Client:
            async def query(self,text):pass
            async def receive_response(self):yield result
        runtime=ClaudeAgentSDKRuntime();runtime.client=Client()
        with self.assertRaisesRegex(RuntimeError,'session limit'):
            async for _ in runtime.send('hello'):pass

    async def test_api_key_refuses_to_open_runtime(self):
        with patch.dict('os.environ', {'ANTHROPIC_API_KEY':'test-only-not-a-real-key'}):
            with self.assertRaisesRegex(RuntimeError,'API billing'):
                await ClaudeAgentSDKRuntime().open('test',[])
