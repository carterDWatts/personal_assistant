import base64
import unittest
from unittest.mock import patch, Mock

from engine.integrations import read_specs, weather, google
from engine.tools import run


class integrations_test(unittest.IsolatedAsyncioTestCase):
    async def test_weather_tool_validates_without_network(self):
        spec = next(t for t in read_specs() if t.name == 'weather_forecast')
        with patch.object(weather, '_forecast') as fetch:
            _, error = await run(spec, {'location': 'Seattle', 'units': 'kelvin'})
            self.assertTrue(error)
            fetch.assert_not_called()

    async def test_weather_returns_freshness_and_limited_hours(self):
        place = {'name':'Seattle', 'admin1':'Washington', 'country':'United States', 'latitude':47.6, 'longitude':-122.3}
        data = {'timezone':'America/Los_Angeles', 'current':{'time':'2026-09-07T12:15'},
            'hourly': {'time':[f'2026-09-07T{h:02}:00' for h in range(24)], 'temperature_2m': list(range(24))},
            'daily': {'time':['2026-09-07'], 'precipitation_sum':[0]}}
        with patch.object(weather, '_get', side_effect=[({'results':[place]},'geo-time'), (data,'fetch-time')]):
            result = await weather.forecast({'location':'Seattle'})
        self.assertEqual(result['fetched_at'], 'fetch-time')
        self.assertEqual(result['next_24_hours'][0]['time'], '2026-09-07T12:00')
        self.assertEqual(result['location'], 'Seattle, Washington, United States')

    async def test_weather_failure_does_not_invent_forecast(self):
        spec = next(t for t in read_specs() if t.name == 'weather_forecast')
        with patch.object(weather, '_forecast', side_effect=TimeoutError):
            text, error = await run(spec, {'location':'Seattle'})
        self.assertTrue(error)
        self.assertIn('temporarily unavailable', text)

    async def test_google_disconnected_does_not_request_data(self):
        spec = next(t for t in read_specs() if t.name == 'google_mail_search')
        with patch.object(google, '_credentials', return_value=None), patch.object(google, 'AuthorizedSession') as session:
            text, error = await run(spec, {})
        self.assertTrue(error)
        self.assertIn('Connect Google', text)
        session.assert_not_called()

    def test_google_auth_uses_pkce_and_stores_in_keychain(self):
        credentials = Mock(refresh_token='test-refresh')
        credentials.has_scopes.return_value = True
        credentials.to_json.return_value = '{"test":"credentials"}'
        flow = Mock()
        flow.run_local_server.return_value = credentials
        with patch.object(google, '_client', return_value={'installed':{'client_id':'test'}}), \
             patch.object(google.InstalledAppFlow, 'from_client_config', return_value=flow) as create, \
             patch.object(google.keyring, 'set_password') as save, \
             patch.object(google, 'status', return_value={'connected':True}):
            self.assertTrue(google.connect()['connected'])
        self.assertTrue(create.call_args.kwargs['autogenerate_code_verifier'])
        self.assertEqual(flow.run_local_server.call_args.kwargs['host'], '127.0.0.1')
        self.assertEqual(flow.run_local_server.call_args.kwargs['port'], 0)
        save.assert_called_once()

    def test_disconnect_only_removes_this_environments_credential(self):
        with patch.object(google.keyring, 'delete_password') as delete, patch.object(google, 'status', return_value={'connected':False}):
            google.disconnect()
        delete.assert_called_once_with(google.SERVICE, google.config.ENV)

    def test_mail_body_prefers_plain_text_and_ignores_attachments(self):
        def part(mime, text, filename=""):
            return {"mimeType":mime,"filename":filename,"body":{"data":base64.urlsafe_b64encode(text.encode()).decode()}}
        payload = {"parts":[part("text/plain","Meeting at noon"),part("text/html","<b>Duplicate</b>"),part("text/plain","Attachment", "notes.txt")]}
        self.assertEqual(google._body(payload), "Meeting at noon")
        self.assertEqual(google._body(part("text/html", "<style>hidden</style><p>Hello</p><script>hidden</script>")), "Hello")

    async def test_calendar_rejects_invalid_times_before_network(self):
        spec = next(t for t in read_specs() if t.name == 'google_calendar_create_event')
        for start, end in [('2026-09-07T16:00', '2026-09-07T17:00'),
                           ('2026-09-07T17:00-07:00', '2026-09-07T16:00-07:00')]:
            with patch.object(google, '_request') as request:
                _, error = await run(spec, {'title':'Gym','start':start,'end':end})
            self.assertTrue(error)
            request.assert_not_called()

    def test_calendar_creation_preserves_offset_and_reuses_id(self):
        args = {'title':'Gym','start':'2026-09-07T16:00-07:00','end':'2026-09-07T17:00-07:00'}
        with patch.object(google, '_request', return_value={'id':'event'}) as request:
            google._create_event(args)
            first = request.call_args.kwargs['body']
            google._create_event(args)
            self.assertEqual(first, request.call_args.kwargs['body'])
        self.assertEqual(first['start']['dateTime'], '2026-09-07T16:00:00-07:00')
        self.assertNotIn('attendees', first)
        self.assertEqual(request.call_args.args[:2], ('POST','calendar/v3/calendars/primary/events'))

    def test_calendar_old_credentials_require_upgrade(self):
        credentials = Mock()
        credentials.has_scopes.return_value = False
        with patch.object(google, '_credentials', return_value=credentials), patch.object(google, 'AuthorizedSession') as session:
            with self.assertRaisesRegex(google.ToolError, 'Enable calendar editing'):
                google._request('POST', 'calendar/v3/calendars/primary/events', body={})
        session.assert_not_called()

    def test_calendar_retry_returns_existing_event(self):
        body = {'id':'abc12','summary':'Gym','description':'','start':{'dateTime':'2026-09-07T16:00:00-07:00'},'end':{'dateTime':'2026-09-07T17:00:00-07:00'}}
        credentials = Mock(valid=True)
        with patch.object(google, '_credentials', return_value=credentials), patch.object(google, 'AuthorizedSession') as session, patch.object(google, '_get', return_value=body):
            session.return_value.__enter__.return_value.request.return_value.status_code = 409
            result = google._request('POST', 'calendar/v3/calendars/primary/events', body=body)
        self.assertEqual(result['id'], 'abc12')

    def test_oauth_refresh_keeps_credentials_out_of_results(self):
        import json
        from engine.integrations.oauth import access_token
        stored=json.dumps({'token':'old','refresh_token':'refresh','client_id':'client','client_secret':'secret','expiry':'2020-01-01T00:00:00Z'})
        response=Mock(status_code=200)
        response.json.return_value={'access_token':'new','refresh_token':'rotated','expires_in':3600}
        with patch('engine.integrations.oauth.requests.post',return_value=response) as post, patch('engine.integrations.oauth.credentials.set_password') as save:
            self.assertEqual(access_token('supabase','service','prod:supabase',stored),'new')
        self.assertEqual(post.call_args.args[0],'https://api.supabase.com/v1/oauth/token')
        self.assertEqual(post.call_args.kwargs['auth'],('client','secret'))
        self.assertFalse(post.call_args.kwargs['allow_redirects'])
        self.assertEqual(json.loads(save.call_args.args[2])['refresh_token'],'rotated')

    def test_expired_oauth_rejection_requests_login_without_leaking_response(self):
        import json
        from engine.integrations.oauth import access_token
        from engine.tools import ConnectionRequired
        stored=json.dumps({'token':'old','refresh_token':'refresh','client_id':'client','client_secret':'secret','expiry':'2020-01-01T00:00:00Z'})
        response=Mock(status_code=400)
        with patch('engine.integrations.oauth.requests.post',return_value=response), patch('engine.integrations.oauth.credentials.set_password') as save:
            with self.assertRaises(ConnectionRequired) as error: access_token('github','service','prod:github',stored)
        self.assertNotIn('secret',str(error.exception));save.assert_not_called()

    async def test_missing_supabase_connection_offers_login_without_network(self):
        from engine.integrations import accounts, github, supabase
        from engine.tools import ConnectionRequired
        with patch.object(accounts.keyring,'get_password',return_value=None),patch.object(accounts.requests,'request') as request:
            with self.assertRaises(ConnectionRequired) as error: supabase._supabase_projects({})
        self.assertEqual(error.exception.action,'supabase_connect');request.assert_not_called()

    def test_repository_file_read_preserves_ref_and_reports_truncation(self):
        from engine.integrations import accounts, github, supabase
        data={'type':'file','encoding':'base64','path':'README.md','sha':'revision','content':base64.b64encode(b'x'*25000).decode()}
        with patch.object(github,'_request',return_value=data) as request:
            result=github._github_file({'owner':'carter','repo':'assistant','path':'README.md','ref':'branch'})
        self.assertTrue(result['truncated']);self.assertEqual(len(result['content']),24000)
        self.assertEqual(request.call_args.kwargs['params'],{'ref':'branch'})
        with patch.object(github,'_request',return_value=data):
            tail=github._github_file({'owner':'carter','repo':'assistant','path':'README.md','ref':'branch','offset':result['next_offset']})
        self.assertEqual(result['content']+tail['content'],'x'*25000)
        self.assertIsNone(tail['next_offset']);self.assertFalse(tail['truncated'])
