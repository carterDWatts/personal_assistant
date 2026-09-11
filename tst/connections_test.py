import json
import unittest
from unittest.mock import Mock, patch

from engine.integrations import google, workspace, services, accounts, notion, todoist, read_specs
from engine.tools import ConnectionRequired, ToolError, run


class connections_test(unittest.IsolatedAsyncioTestCase):
    async def test_each_missing_service_prompts_without_network(self):
        cases = {'google_task_lists': ({}, 'google_tasks'), 'google_drive_search': ({}, 'google_drive'),
                 'google_contacts_search': ({'query': 'Ada'}, 'google_contacts'),
                 'todoist_tasks': ({}, 'todoist_connect'), 'notion_search': ({}, 'notion_connect'),
                 'github_issues': ({'query': 'assignee:@me is:open'}, 'github_connect')}
        with patch.object(google, '_credentials', return_value=None), patch.object(accounts.keyring, 'get_password', return_value=None), \
             patch.object(google, 'AuthorizedSession') as google_http, patch.object(accounts.requests, 'request') as service_http:
            for name, (args, action) in cases.items():
                output, error = await run(next(s for s in read_specs() if s.name == name), args)
                self.assertTrue(error)
                self.assertEqual(json.loads(output)['connection_action'], action)
            google_http.assert_not_called(); service_http.assert_not_called()

    def test_google_extra_grant_is_independent_of_calendar_and_mail(self):
        credentials = Mock(refresh_token='test-refresh', granted_scopes=google.CONNECTIONS['google_tasks'][1])
        credentials.has_scopes.return_value = True
        credentials.to_json.return_value = 'test-json'
        flow = Mock(); flow.run_local_server.return_value = credentials
        with patch.object(google, '_client', return_value={'installed': {'client_id':'test'}}), \
             patch.object(google.InstalledAppFlow, 'from_client_config', return_value=flow) as create, \
             patch.object(google.keyring, 'set_password') as save, patch.object(google, 'status', return_value={}):
            google.connect('google_tasks')
        self.assertEqual(create.call_args.kwargs['scopes'], google.CONNECTIONS['google_tasks'][1])
        self.assertEqual(save.call_args.args[1], google.config.ENV + ':google_tasks')
        self.assertNotIn(google.WRITE_SCOPE, create.call_args.kwargs['scopes'])

    def test_rejected_google_grant_does_not_replace_credentials(self):
        credentials = Mock(refresh_token='test-refresh', granted_scopes=[])
        flow = Mock(); flow.run_local_server.return_value = credentials
        with patch.object(google, '_client', return_value={'installed':{'client_id':'test'}}), \
             patch.object(google.InstalledAppFlow, 'from_client_config', return_value=flow), patch.object(google.keyring, 'set_password') as save:
            with self.assertRaises(ToolError): google.connect('google_contacts')
        save.assert_not_called()

    def test_google_read_caps_response_and_uses_correct_scope_and_host(self):
        response = Mock(status_code=200, ok=True)
        response.iter_content.return_value = [b'x' * 64001]
        response.__enter__ = Mock(return_value=response); response.__exit__ = Mock(return_value=False)
        credentials = Mock(valid=True)
        with patch.object(google, '_credentials', return_value=credentials) as creds, patch.object(google, 'AuthorizedSession') as session:
            session.return_value.__enter__.return_value.get.return_value = response
            result = google.read_data('google_drive', 'drive/v3/files/abc/export', text=True)
            self.assertTrue(result['truncated']); self.assertEqual(len(result['text']), 64000)
            creds.assert_called_once_with('google_drive')
            response.iter_content.return_value = [b'{"values":[]}']
            google.read_data('google_drive', 'sheets/v4/spreadsheets/abc/values/A1')
            self.assertEqual(session.return_value.__enter__.return_value.get.call_args.args[0],
                             'https://sheets.googleapis.com/v4/spreadsheets/abc/values/A1')

    def test_drive_query_escaping_and_pagination(self):
        with patch.object(workspace, 'read_data', return_value={'files': [], 'nextPageToken':'next'}) as request:
            result = workspace._drive_search({'query': "Bob's \\ files", 'page_token':'page'})
        self.assertEqual(request.call_args.args[2]['q'], "trashed = false and (name contains 'Bob\\'s \\\\ files' or fullText contains 'Bob\\'s \\\\ files')")
        self.assertEqual(request.call_args.args[2]['pageToken'], 'page')
        self.assertEqual(result['next_page_token'], 'next')
        self.assertIn('fetched_at', result)

    def test_contacts_refresh_search_cache_and_do_not_claim_exhaustive_results(self):
        with patch.object(workspace, 'read_data', return_value={'results': []}) as request:
            result = workspace._contacts({'query':'Ada'})
        self.assertEqual([c.args[2]['query'] for c in request.call_args_list], ['', 'Ada'])
        self.assertIn('Prefix', result['search_note'])

    def test_tasks_preserve_due_dates_and_page_tokens(self):
        item = {'id':'a','title':'Call','due':'2026-09-08T00:00:00Z','status':'needsAction'}
        with patch.object(workspace, 'read_data', return_value={'items':[item], 'nextPageToken':'next'}) as request:
            result = workspace._tasks({'list_id':'a/b', 'completed':True})
        self.assertIn('a%2Fb', request.call_args.args[1])
        self.assertEqual(request.call_args.args[2]['showHidden'], 'true')
        self.assertEqual(result['tasks'][0]['due'], item['due'])
        self.assertEqual(result['next_page_token'], 'next')

    def test_service_credentials_are_validated_before_saving(self):
        with patch.object(accounts, '_request', side_effect=ToolError('denied')), patch.object(accounts.keyring, 'set_password') as save:
            with self.assertRaises(ToolError): services.connect('notion', 'test-only-token')
        save.assert_not_called()
        with patch.object(accounts, '_request', return_value={}) as request, patch.object(accounts.keyring, 'set_password') as save, patch.object(accounts, 'status', return_value={'notion':{'connected':True}}):
            output = services.connect('notion', 'test-only-token')
        self.assertNotIn('test-only-token', json.dumps(output))
        self.assertEqual(save.call_args.args[1], accounts.config.ENV + ':notion')
        self.assertEqual(request.call_args.args[1], 'users/me')

    def test_service_http_rejects_redirects_and_never_returns_error_body(self):
        for code in (302,401,403,429,500):
            response = Mock(status_code=code)
            response.__enter__ = Mock(return_value=response); response.__exit__ = Mock(return_value=False)
            with patch.object(accounts.requests, 'request', return_value=response) as request:
                with self.assertRaises(ToolError) as error:
                    accounts._request('github', 'user', token='test-only-token')
            self.assertNotIn('test-only-token', str(error.exception))
            self.assertFalse(request.call_args.kwargs['allow_redirects'])
            response.iter_content.assert_not_called()

    def test_notion_exposes_nested_blocks_and_pagination(self):
        data = {'results':[{'id':'a','type':'paragraph','has_children':True,'paragraph':{'rich_text':[{'plain_text':'hello'}]}}],
                'next_cursor':'next', 'has_more':True}
        with patch.object(notion, '_request', return_value=data):
            result = notion._notion_read({'block_id':'a'})
        self.assertEqual(result['blocks'][0]['text'], 'hello')
        self.assertTrue(result['blocks'][0]['has_children'])
        self.assertTrue(result['has_more'])

    def test_notion_unauthorized_refreshes_once_with_json_and_preserves_rotation(self):
        stored = json.dumps({'token':'old', 'refresh_token':'refresh', 'client_id':'client', 'client_secret':'secret'})
        denied = Mock(status_code=401)
        success = Mock(status_code=200)
        success.iter_content.return_value = [b'{"results":[]}']
        for response in (denied, success):
            response.__enter__ = Mock(return_value=response); response.__exit__ = Mock(return_value=False)
        refreshed = Mock(status_code=200)
        refreshed.json.return_value = {'access_token':'new','refresh_token':'rotated'}
        with patch.object(accounts.keyring, 'get_password', return_value=stored), \
             patch.object(accounts.keyring, 'set_password') as save, \
             patch.object(accounts.requests, 'request', side_effect=[denied,success]) as request, \
             patch('engine.integrations.oauth.requests.post', return_value=refreshed) as renew:
            self.assertEqual(accounts._request('notion','search',body={}), {'results':[]})
        self.assertEqual(renew.call_args.kwargs['json'], {'grant_type':'refresh_token','refresh_token':'refresh'})
        self.assertNotIn('data', renew.call_args.kwargs)
        self.assertEqual(renew.call_args.kwargs['auth'], ('client','secret'))
        self.assertEqual(json.loads(save.call_args.args[2])['refresh_token'], 'rotated')
        self.assertEqual(request.call_count, 2)
        self.assertEqual(request.call_args.kwargs['headers']['Authorization'], 'Bearer new')

    def test_notion_refresh_failure_requires_sign_in_without_replacing_access(self):
        from engine.integrations.oauth import access_token
        stored = json.dumps({'token':'old','refresh_token':'refresh','client_id':'client','client_secret':'secret'})
        with patch('engine.integrations.oauth.requests.post', return_value=Mock(status_code=400)), \
             patch.object(accounts.keyring, 'set_password') as save:
            with self.assertRaises(ConnectionRequired): access_token('notion','service','account',stored,force=True)
        save.assert_not_called()

    def test_notion_connect_uses_sign_in_instead_of_requesting_a_token(self):
        with patch('engine.integrations.oauth.connect_local') as login, patch.object(accounts, 'status', return_value={'notion':{}}):
            accounts.connect('notion', None)
        login.assert_called_once_with('notion', accounts.SERVICE, accounts.config.ENV + ':notion')

    def test_todoist_preserves_deadlines_and_pagination(self):
        with patch.object(todoist, '_request', return_value={'results':[{'id':'1','content':'Work','deadline':{'date':'2026-09-08'}}], 'next_cursor':'next'}):
            result = todoist._todoist({})
        self.assertEqual(result['tasks'][0]['deadline']['date'], '2026-09-08')
        self.assertEqual(result['next_cursor'], 'next')

    async def test_bad_ids_do_not_reach_provider(self):
        spec = next(s for s in read_specs() if s.name == 'google_drive_read')
        with patch.object(workspace, 'read_data') as request:
            _, error = await run(spec, {'file_id':'https://example.com/steal'})
        self.assertTrue(error); request.assert_not_called()

    def test_all_supported_actions_reach_chat(self):
        from engine.desktop import DesktopIO
        with patch('engine.desktop.emit') as emit:
            for action in google.CONNECTION_ACTIONS | services.CONNECTION_ACTIONS:
                DesktopIO().tool_result({'is_error':True,'content':json.dumps({'connection_action':action})})
                self.assertEqual(emit.call_args.kwargs['action'], action)

    async def test_secure_setup_never_enters_session_or_output(self):
        import asyncio
        import queue
        from engine import desktop
        incoming = queue.Queue()
        incoming.put(json.dumps({'type':'service_connect','provider':'todoist','token':'test-private-value'}))
        events = []
        class Input:
            def readline(self):
                try: return incoming.get(timeout=3) + '\n'
                except queue.Empty: return ''
        def emit(kind, **values):
            events.append({'type':kind, **values})
            if values.get('completed'): incoming.put(json.dumps({'type':'quit'}))
        with patch.object(desktop, 'load_settings'), patch.object(desktop.sys, 'stdin', Input()), \
             patch.object(desktop, 'emit', emit), patch.object(google, 'status', return_value={}), \
             patch.object(services, 'status', return_value={'todoist':{'connected':True}}), \
             patch.object(services, 'connect') as connect, patch('engine.engine.Session') as session:
            await asyncio.wait_for(desktop.main(), 5)
        connect.assert_called_once_with('todoist', 'test-private-value')
        session.assert_not_called()
        self.assertNotIn('test-private-value', json.dumps(events))
        self.assertTrue(any(event.get('completed') for event in events))

    async def test_missing_host_keychain_produces_connection_action(self):
        spec = next(s for s in read_specs() if s.name == 'todoist_tasks')
        with patch.object(accounts.keyring, 'get_password', side_effect=accounts.keyring.errors.NoKeyringError):
            result, error = await run(spec, {})
        self.assertTrue(error)
        self.assertEqual(json.loads(result)['connection_action'], 'todoist_connect')
