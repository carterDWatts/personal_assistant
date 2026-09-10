import asyncio
import unittest
from types import SimpleNamespace

from engine.host import supervise, ReplyDeadline, Host


class ReplyDeadlineTest(unittest.TestCase):
    def test_waiting_notice_is_once_and_status_traffic_cannot_extend_deadline(self):
        deadline = ReplyDeadline(100)
        self.assertIsNone(deadline.check(107.9, False))
        self.assertEqual(deadline.check(108, False), 'waiting')
        self.assertIsNone(deadline.check(109, False))
        self.assertEqual(deadline.check(145, False), 'timeout')

    def test_streaming_reply_keeps_its_full_turn_budget(self):
        deadline = ReplyDeadline(100)
        self.assertIsNone(deadline.check(145, True))
        self.assertIsNone(deadline.check(399, True))
        self.assertEqual(deadline.check(400, True), 'timeout')


class HostReplyTest(unittest.IsolatedAsyncioTestCase):
    async def test_no_output_deadline_publishes_error_then_terminal_failure(self):
        from unittest.mock import patch
        published, finished, interrupted = [], [], []
        relay = SimpleNamespace(
            publish=lambda turn, batch: published.extend(batch),
            cancelled=lambda turn: False,
            heartbeat=lambda: None,
            finish=lambda turn, status: finished.append(status))
        host = Host(relay, None, runtime_factory=lambda: None)
        async def answer(turn):
            await asyncio.Future()
        async def interrupt(task):
            interrupted.append(True)
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        async def noop(): pass
        host.answer, host.interrupt = answer, interrupt
        host.refresh_day = host.close_session = noop
        with patch.object(ReplyDeadline, 'check', return_value='timeout'):
            await host.process({'id': 'test'})
        self.assertEqual(finished, ['failed'])
        self.assertEqual(interrupted, [True])
        self.assertEqual([p['type'] for p in published], ['error', 'timing'])
        self.assertIn('saved', published[0]['message'])
        self.assertEqual(published[1]['reply_deadline_exceeded'], 1)
        self.assertIsNone(host.active)

    async def test_runtime_failure_has_neutral_retry_error(self):
        published, finished = [], []
        relay = SimpleNamespace(
            publish=lambda turn, batch: published.extend(batch),
            cancelled=lambda turn: False, heartbeat=lambda: None,
            finish=lambda turn, status: finished.append(status))
        host = Host(relay, None, runtime_factory=lambda: None)
        async def answer(turn): raise RuntimeError('private error detail')
        async def noop(): pass
        host.answer = answer
        host.refresh_day = host.close_session = noop
        await host.process({'id': 'test'})
        self.assertEqual(finished, ['failed'])
        self.assertEqual(published[0]['type'], 'error')
        self.assertNotIn('private', str(published))
        self.assertNotIn('login', str(published))


class HostSupervisionTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.closed = set()
        self.host = SimpleNamespace(stopping=asyncio.Event(), ready=asyncio.Event())

        async def run():
            try:
                self.host.ready.set()
                await self.host.stopping.wait()
            finally:
                self.closed.add('conversation')

        self.host.run = run

    async def worker(self, name):
        try:
            await asyncio.Future()
        finally:
            self.closed.add(name)

    async def test_background_failure_stops_and_joins_every_service(self):
        async def fail():
            await self.host.ready.wait()
            raise ValueError('notification failure')

        with self.assertRaisesRegex(ValueError, 'notification failure'):
            await supervise(self.host, {
                'notifications': fail(),
                'sources': self.worker('sources'),
                'commands': self.worker('commands'),
            })
        self.assertTrue(self.host.stopping.is_set())
        self.assertEqual(self.closed, {'conversation', 'sources', 'commands'})

    async def test_unexpected_successful_exit_is_a_failure(self):
        async def exit_early():
            await self.host.ready.wait()

        with self.assertRaisesRegex(RuntimeError, 'sources stopped unexpectedly'):
            await supervise(self.host, {'sources': exit_early(), 'memory': self.worker('memory')})
        self.assertEqual(self.closed, {'conversation', 'memory'})

    async def test_host_failure_stops_background_work(self):
        async def fail():
            raise ValueError('host failure')

        self.host.run = fail
        with self.assertRaisesRegex(ValueError, 'host failure'):
            await supervise(self.host, {'memory': self.worker('memory')})
        self.assertEqual(self.closed, {'memory'})

    async def test_shutdown_allows_the_host_to_finish(self):
        async def stop():
            await self.host.ready.wait()
            self.host.stopping.set()

        await supervise(self.host, {'signal': stop(), 'memory': self.worker('memory')})
        self.assertEqual(self.closed, {'conversation', 'memory'})

    async def test_cancellation_does_not_leave_background_tasks(self):
        task = asyncio.create_task(supervise(self.host, {'memory': self.worker('memory')}))
        await self.host.ready.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertEqual(self.closed, {'conversation', 'memory'})
