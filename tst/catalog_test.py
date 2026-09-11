import json
from pathlib import Path
from unittest import TestCase
from unittest.mock import patch

from engine.integrations import accounts, discovery, google, oauth, services
from engine.integrations.catalog import ACCOUNT_PROVIDERS, GOOGLE_GRANTS, PROVIDERS
from engine.tools import ToolError


class catalog_test(TestCase):
    def test_registered_services_have_tools_and_unambiguous_connection_actions(self):
        raw = json.loads(Path('shared/integrations.json').read_text())
        self.assertEqual(len(PROVIDERS), len(raw['providers']))
        names = [spec.name for spec in services.specs()]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(set(ACCOUNT_PROVIDERS), {name.split('_', 1)[0] for name in names})
        for provider in PROVIDERS.values():
            for domain in provider['domains']:
                self.assertEqual(discovery.adapter('https://' + domain)[0], provider['id'])
                self.assertIsNone(discovery.adapter('https://' + domain + '.attacker.example'))
        self.assertEqual(google.CONNECTION_ACTIONS, {grant['action'] for grant in GOOGLE_GRANTS.values()})
        self.assertEqual(google.SCOPES, GOOGLE_GRANTS['calendar_write']['scopes'])

    def test_token_only_services_cannot_start_unconfigured_oauth(self):
        for provider, definition in ACCOUNT_PROVIDERS.items():
            if definition['auth'] != 'token':
                continue
            with patch.object(oauth, 'connect_local') as login, patch.object(accounts.keyring, 'set_password') as save:
                with self.assertRaises(ToolError):
                    accounts.connect(provider, None)
            login.assert_not_called()
            save.assert_not_called()

    def test_local_registration_status_is_separate_from_saved_access(self):
        with patch.dict('os.environ', {}, clear=True), patch('keyring.get_password', return_value=None):
            self.assertFalse(oauth.configured('github'))
            self.assertFalse(oauth.configured('notion'))
        with patch.dict('os.environ', {}, clear=True), patch('keyring.get_password', return_value='{"client_id":"test", "client_secret":"test"}'):
            self.assertTrue(oauth.configured('github'))

    def test_personal_tokens_still_work_after_oauth_refactor(self):
        with patch.object(oauth.requests, 'post') as request:
            self.assertEqual(oauth.access_token('notion', 'service', 'test:notion', 'test-token'), 'test-token')
        request.assert_not_called()
