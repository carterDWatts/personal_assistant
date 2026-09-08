import asyncio
import uuid

import psycopg

from engine.db import Map, jsonb
from engine.host import Host
from engine.relay import Relay, LeaseLost
from engine.runtime import Event
from tst.helpers import MapTest, FakeRuntime, say


class relay_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner, self.device = uuid.uuid4(), uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)', (self.owner,))
        self.client('register', {'name': 'Test phone'})
        self.relay = Relay(self.map)

    def tearDown(self):
        if getattr(self, 'map', None):
            self.map.execute('truncate assistant.owner,assistant.host cascade')
        super().tearDown()

    def client(self, action, args=None, owner=None, device=None):
        return self.map.value('select public.assistant_client(%s,%s,%s,%s)',
                              (owner or self.owner, device or self.device, action, jsonb(args or {})))

    def submit(self, text='Hello', message=None):
        return self.client('submit', {'client_message_id': str(message or uuid.uuid4()), 'text': text})

    def test_owner_and_revocation_are_enforced(self):
        with self.assertRaisesRegex(psycopg.Error, 'account_denied'):
            self.client('bootstrap', owner=uuid.uuid4())
        with self.assertRaisesRegex(psycopg.Error, 'device_denied'):
            self.client('events', device=uuid.uuid4())
        self.client('revoke', {'device_id': str(self.device)})
        for action in ('bootstrap', 'events', 'register'):
            with self.assertRaisesRegex(psycopg.Error, 'device_denied'):
                self.client(action, {'name': 'Reused device'})

    def test_retry_is_idempotent_and_another_turn_is_busy(self):
        message = uuid.uuid4()
        first = self.submit(message=message)
        self.assertEqual(first, self.submit(message=message))
        with self.assertRaisesRegex(psycopg.Error, 'idempotency_conflict'):
            self.submit('Changed text', message)
        with self.assertRaisesRegex(psycopg.Error, 'conversation_busy'):
            self.submit()
        self.assertEqual(self.map.value('select count(*) from assistant.turns'), 1)

    def test_offline_submit_and_queued_cancel(self):
        self.assertFalse(self.client('bootstrap')['host']['online'])
        turn = self.submit()
        self.assertEqual(turn['status'], 'queued')
        self.client('cancel', turn)
        self.assertEqual(self.client('events')['events'][-1]['payload'], {'type': 'end', 'status': 'cancelled'})
        self.assertTrue(self.relay.acquire())
        self.assertIsNone(self.relay.claim())

    def test_day_panel_uses_owner_timezone_and_emits_only_changes(self):
        async def check():
            self.map.execute("update assistant.owner set timezone='Pacific/Kiritimati'")
            self.map.execute("insert into memory.plans(day,item,origin,created_by)"
                             " values((now() at time zone 'Pacific/Kiritimati')::date,'Go for a walk','user','test')")
            day = self.client('bootstrap')['day']
            self.assertEqual(day['plans'], [{'item': 'Go for a walk', 'status': 'planned'}])
            relay_map = Map(self.map.url)
            relay = Relay(relay_map)
            relay.acquire()
            host = Host(relay, self.map)
            try:
                await host.refresh_day()
                await host.refresh_day()
                events = self.client('events')['events']
                self.assertEqual(len(events), 2)
                self.assertEqual(events[0]['payload'], {'type': 'map', **day})
                self.assertIsNone(events[0]['turn_id'])
                self.map.execute("update memory.plans set status='done'")
                await host.refresh_day()
                self.assertEqual(self.client('events')['events'][-2]['payload']['plans'][0]['status'], 'done')
            finally:
                relay_map.close()
        self.run_async(check())

    def test_takeover_fences_old_worker_and_never_replays_running_turn(self):
        self.submit()
        self.assertTrue(self.relay.acquire())
        turn = self.relay.claim()
        other = Relay(self.map)
        self.assertFalse(other.acquire())
        self.map.execute("update assistant.host set lease_until=now()-interval '1 second'")
        self.assertTrue(other.acquire())
        self.assertIsNone(other.claim())
        with self.assertRaises(LeaseLost):
            self.relay.publish(turn['id'], [{'type': 'delta', 'text': 'stale'}])
        with self.assertRaises(LeaseLost):
            self.relay.heartbeat()
        self.assertEqual(self.client('events')['events'][-1]['payload']['status'], 'failed')

    def test_cancel_wins_completion_race_and_replay_pages(self):
        self.submit()
        self.relay.acquire()
        turn = self.relay.claim()
        self.relay.publish(turn['id'], [{'type': 'delta', 'text': str(i)} for i in range(205)])
        bootstrap = self.client('bootstrap')
        replay = self.client('events', {'after': bootstrap['replay_after']})
        self.assertEqual(replay['events'][0]['payload']['type'], 'start')
        self.assertLess(bootstrap['replay_after'], bootstrap['cursor'])
        self.client('cancel', {'turn_id': str(turn['id'])})
        self.relay.finish(turn['id'], 'completed')
        page = self.client('events')
        self.assertTrue(page['has_more'])
        rest = self.client('events', {'after': page['events'][-1]['cursor']})
        self.assertEqual(rest['events'][-1]['payload']['status'], 'cancelled')
        events = page['events'] + rest['events']
        self.assertEqual(len(events), 207)
        self.assertEqual(len({e['cursor'] for e in events}), 207)
        self.assertEqual(events[0]['conversation_id'], self.client('bootstrap')['conversation_id'])

    def test_public_cannot_call_privileged_gateway_rpc(self):
        self.assertFalse(self.map.value("select has_function_privilege('public',"
                                        " 'public.assistant_client(uuid,uuid,text,jsonb)','execute')"))
        # Mirror the hosted service role, rather than accidentally testing only as postgres.
        with self.map.conn.transaction():
            self.map.execute('set local role service_role')
            self.assertIn('history', self.client('bootstrap'))

    def test_host_streams_and_reuses_runtime(self):
        async def check():
            relay_map = Map(self.map.url)
            relay = Relay(relay_map)
            relay.acquire()
            runtime = FakeRuntime([[Event('text', text='Hello '), say('Hello there.')], [say('Still here.')]])
            host = Host(relay, self.map, lambda: runtime)
            try:
                for _ in range(2):
                    self.submit()
                    await host.process(relay.claim())
                self.assertEqual(len(runtime.sent), 2)
                self.assertEqual(self.map.value('select count(*) from memory.conversations'), 1)
                self.assertEqual(self.map.value("select count(*) from assistant.turns where status='completed'"), 2)
                events = self.client('events')['events']
                self.assertIn({'type': 'replace', 'text': 'Still here.'}, [e['payload'] for e in events])
                self.assertEqual(self.client('bootstrap')['history'][-1]['content'], 'Still here.')
                self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'), 2)
            finally:
                await host.close_session()
                relay_map.close()
        self.run_async(check())

    def test_failed_login_is_terminal_and_does_not_expose_diagnostics(self):
        async def check():
            class Failed(FakeRuntime):
                async def open(self, *args, **kwargs):
                    raise RuntimeError('private credential value')
            relay_map = Map(self.map.url)
            relay = Relay(relay_map)
            relay.acquire()
            self.submit()
            host = Host(relay, self.map, lambda: Failed([]))
            try:
                await host.process(relay.claim())
                events = self.client('events')['events']
                self.assertEqual(events[-1]['payload']['status'], 'failed')
                self.assertNotIn('private credential value', str(events))
                self.assertIsNone(host.session)
            finally:
                await host.close_session()
                relay_map.close()
        self.run_async(check())

    def test_host_cancels_and_closes_runtime(self):
        async def check():
            class Slow(FakeRuntime):
                async def send(self, text):
                    yield Event('text', text='A partial reply')
                    await asyncio.sleep(60)
            relay_map = Map(self.map.url)
            relay = Relay(relay_map)
            relay.acquire()
            self.submit()
            turn = relay.claim()
            runtime = Slow([])
            host = Host(relay, self.map, lambda: runtime)
            task = asyncio.create_task(host.process(turn))
            try:
                await asyncio.sleep(.2)
                self.client('cancel', {'turn_id': str(turn['id'])})
                await asyncio.wait_for(task, 3)
                self.assertTrue(runtime.closed)
                self.assertEqual(self.client('events')['events'][-1]['payload']['status'], 'cancelled')
            finally:
                task.cancel()
                await host.close_session()
                relay_map.close()
        self.run_async(check())

    def test_clear_preserves_memory_and_restarts_runtime(self):
        async def check():
            self.map.execute("insert into memory.plans(day,item,origin,created_by) values(current_date,'Keep this plan','user','test')")
            relay_map = Map(self.map.url)
            relay = Relay(relay_map); relay.acquire()
            first, second = FakeRuntime([[say('Old reply.')]]), FakeRuntime([[say('Fresh reply.')]])
            runtimes = iter([first, second])
            host = Host(relay, self.map, lambda: next(runtimes))
            try:
                self.submit('Old conversation detail')
                await host.process(relay.claim())
                segment = host.session.segment_id
                original_messages = self.map.value('select count(*) from memory.messages')
                request_id = str(uuid.uuid4())
                cleared = self.client('clear', {'request_id':request_id})
                self.assertEqual(cleared, self.client('clear', {'request_id':request_id}))
                self.assertEqual(cleared, self.client('clear'))
                self.assertEqual(self.client('bootstrap')['history'], [])
                self.assertEqual(self.map.value('select count(*) from memory.messages'), original_messages + 1)
                self.assertEqual(self.map.value('select count(*) from memory.plans'), 1)
                self.assertEqual(self.map.value('select count(*) from memory.memory_jobs'), 1)
                self.assertEqual(self.client('events')['events'][-1]['payload']['type'], 'history')
                self.submit('Hello again')
                await host.process(relay.claim())
                self.assertTrue(first.closed)
                self.assertNotEqual(segment, host.session.segment_id)
                self.assertIsNone(second.opened['resume'])
                self.assertNotIn('Old conversation detail', second.sent[0])
                self.assertIn('Keep this plan', second.sent[0])
                # A late retry must not clear a conversation that has since continued.
                self.assertEqual(cleared, self.client('clear', {'request_id':request_id}))
                self.assertEqual(self.client('bootstrap')['history'][-1]['content'], 'Fresh reply.')
            finally:
                await host.close_session(); relay_map.close()
        self.run_async(check())

    def test_clear_rejects_other_accounts_revoked_devices_and_active_turns(self):
        with self.assertRaisesRegex(psycopg.Error, 'account_denied'):
            self.client('clear', owner=uuid.uuid4())
        with self.assertRaisesRegex(psycopg.Error, 'device_denied'):
            self.client('clear', device=uuid.uuid4())
        self.submit()
        with self.assertRaisesRegex(psycopg.Error, 'conversation_busy'):
            self.client('clear')
        self.relay.acquire(); self.relay.claim()
        with self.assertRaisesRegex(psycopg.Error, 'conversation_busy'):
            self.client('clear')
        self.assertEqual(self.map.value("select count(*) from memory.messages where payload->>'event'='chat_cleared'"), 0)
