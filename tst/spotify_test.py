import asyncio
import json
import uuid
from unittest import IsolatedAsyncioTestCase
from unittest.mock import AsyncMock, Mock, patch
from types import SimpleNamespace

import psycopg
from engine.db import jsonb
from engine.integrations import accounts, spotify
from engine.relay import Relay
from engine.tools import ToolError
from tst.helpers import MapTest

EPISODE = 'spotify:episode:' + 'a' * 22


class spotify_test(IsolatedAsyncioTestCase):
    async def test_play_requires_a_real_content_uri_and_seek_requires_position(self):
        controller = AsyncMock()
        spec = spotify.specs(controller)[-1]
        for args in ({'action': 'play'}, {'action': 'play', 'uri': 'https://attacker.example'}, {'action': 'seek'}):
            with self.assertRaises(ToolError): await spec.fn(args)
        controller.assert_not_called()

    async def test_local_commands_require_connection_and_return_actual_player_result(self):
        controller = AsyncMock(return_value={'verified': False, 'is_playing': False})
        with patch.object(spotify, 'request', return_value={}) as request:
            self.assertFalse((await spotify.specs(controller)[-1].fn({'action': 'play', 'uri': EPISODE}))['verified'])
        request.assert_called_once_with('me')
        controller.assert_awaited_once_with({'action': 'play', 'uri': EPISODE})
        with patch.object(spotify, 'request', side_effect=ToolError('connect')):
            with self.assertRaises(ToolError): await spotify.specs(controller)[-1].fn({'action': 'resume'})
        self.assertEqual(controller.await_count, 1)

    def test_no_remote_player_is_selected_implicitly(self):
        with patch.object(spotify, 'request') as request:
            with self.assertRaises(ToolError): spotify.playback({'action': 'resume'})
        request.assert_not_called()

    def test_episode_playback_is_sent_to_explicit_device_and_acceptance_is_not_success(self):
        response = {'is_playing': True, 'device': {'id': 'phone'}, 'item': {'uri': 'spotify:episode:' + 'b' * 22}}
        with patch.object(spotify, 'request', side_effect=[None, response]) as request:
            result = spotify.playback({'action': 'play', 'uri': EPISODE, 'device_id': 'phone'})
        self.assertEqual(request.call_args_list[0].kwargs, {'method': 'PUT', 'params': {'device_id': 'phone'}, 'body': {'uris': [EPISODE]}})
        self.assertTrue(result['accepted']); self.assertFalse(result['verified'])

    def test_empty_spotify_responses_are_valid_and_errors_do_not_leak_provider_body(self):
        response = Mock(status_code=204)
        response.__enter__ = Mock(return_value=response); response.__exit__ = Mock(return_value=False)
        response.iter_content.return_value = []
        with patch.object(accounts.requests, 'request', return_value=response):
            self.assertIsNone(accounts._request('spotify', 'me/player/pause', method='PUT', token='test-token'))
        for status in (401, 403, 404, 429):
            response.status_code = status
            with patch.object(accounts.requests, 'request', return_value=response):
                with self.assertRaises(ToolError) as error: accounts._request('spotify', 'me/player/play', token='test-token')
            self.assertNotIn('test-token', str(error.exception))

    def test_search_and_episodes_preserve_specific_playable_uris(self):
        value = {'name': 'A podcast episode', 'uri': EPISODE, 'is_playable': True, 'release_date': '2026-09-08'}
        with patch.object(spotify, 'request', return_value={'episodes': {'items': [value]}}):
            self.assertEqual(spotify.search({'query': 'podcast', 'type': 'episode'})['items'][0]['uri'], EPISODE)
        with patch.object(spotify, 'request', return_value={'items': [value], 'next': 'next'}):
            self.assertEqual(spotify.episodes({'show_id': 'a' * 22})['next_offset'], 10)


class spotify_delivery_test(MapTest):
    def setUp(self):
        super().setUp()
        self.map.execute('truncate assistant.owner,assistant.host cascade')
        self.owner, self.device = uuid.uuid4(), uuid.uuid4()
        self.map.execute('insert into assistant.owner(user_id) values(%s)', (self.owner,))
        self.client('register', {'name': 'Test phone'})
        self.map.execute("insert into assistant.credentials(user_id,slot,ciphertext) values(%s,'spotify','test-only')", (self.owner,))
        self.relay = Relay(self.map); self.relay.acquire()
        self.client('submit', {'text': 'Play my podcast', 'client_message_id': str(uuid.uuid4())})
        self.turn = self.relay.claim()['id']; self.command = uuid.uuid4()
        self.map.execute('insert into assistant.spotify_commands(id,user_id,device_id,turn_id,command) values(%s,%s,%s,%s,%s)',
                         (self.command, self.owner, self.device, self.turn, jsonb({'action': 'play', 'uri': EPISODE})))

    def tearDown(self):
        if getattr(self, 'map', None): self.map.execute('truncate assistant.owner,assistant.host cascade')
        super().tearDown()

    def client(self, action, args, device=None):
        return self.map.value('select public.assistant_client(%s,%s,%s,%s)', (self.owner, device or self.device, action, jsonb(args)))

    def command_call(self, action, result=None, device=None):
        return self.map.value('select public.assistant_spotify(%s,%s,%s,%s)',
            (self.owner, device or self.device, action, jsonb({'command_id': str(self.command), 'result': result})))

    def test_command_claim_is_one_time_and_result_is_idempotent(self):
        self.assertEqual(self.command_call('claim')['command']['uri'], EPISODE)
        self.assertEqual(self.command_call('claim'), {'state': 'claimed'})
        self.command_call('finish', {'verified': True})
        self.command_call('finish', {'verified': False})
        self.assertEqual(self.map.value('select result from assistant.spotify_commands where id=%s', (self.command,)), {'verified': True})

    def test_other_device_and_unclaimed_result_are_rejected(self):
        other = uuid.uuid4(); self.client('register', {'name': 'Other phone'}, device=other)
        for action, device in [('claim', other), ('finish', self.device)]:
            with self.assertRaises(psycopg.Error): self.command_call(action, {'verified': True}, device)
        self.map.execute('update assistant.devices set revoked_at=now() where id=%s', (self.device,))
        with self.assertRaises(psycopg.Error): self.command_call('claim')

    def test_expired_cancelled_and_replaced_host_commands_cannot_play(self):
        for sql in ["update assistant.spotify_commands set expires_at=now()-interval '1 second'",
                    "update assistant.turns set cancel_requested=true", "update assistant.host set worker_id=gen_random_uuid()"]:
            with self.map.conn.transaction(force_rollback=True):
                self.map.execute(sql)
                self.assertEqual(self.command_call('claim'), {'state': 'expired'})

    def test_untrusted_result_size_and_database_permissions(self):
        self.command_call('claim')
        with self.assertRaises(psycopg.Error): self.command_call('finish', {'error': 'x' * 5000})
        for role in ('anon', 'authenticated'):
            self.assertFalse(self.map.value("select has_function_privilege(%s,'public.assistant_spotify(uuid,uuid,text,jsonb)','EXECUTE')", (role,)))

    def test_host_handoff_returns_phone_receipt_and_expires_on_completion_or_cancel(self):
        async def exercise(cancel):
            async def call(method, *args): return method(*args)
            host = SimpleNamespace(relay=self.relay, active=self.turn, call=call)
            pending = asyncio.create_task(spotify.phone_control(host, {'action': 'play', 'uri': EPISODE}))
            await asyncio.sleep(0)
            event = self.map.row("select user_id,payload from assistant.events where payload->>'type'='spotify_command' order by cursor desc limit 1")
            self.assertEqual(event['user_id'], self.owner)
            self.assertEqual(event['payload']['device_id'], str(self.device))
            self.assertNotIn('token', json.dumps(event['payload']))
            self.command = uuid.UUID(event['payload']['command_id'])
            if cancel:
                pending.cancel()
                with self.assertRaises(asyncio.CancelledError): await pending
            else:
                self.assertEqual(self.command_call('claim')['command']['uri'], EPISODE)
                self.command_call('finish', {'verified': True, 'uri': EPISODE})
                self.assertEqual(await asyncio.wait_for(pending, 2), {'verified': True, 'uri': EPISODE})
            self.assertEqual(self.command_call('claim'), {'state': 'expired'})
        asyncio.run(exercise(False))
        asyncio.run(exercise(True))
