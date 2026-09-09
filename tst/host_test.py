import asyncio
import unittest
from types import SimpleNamespace

from engine.host import supervise


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
