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
